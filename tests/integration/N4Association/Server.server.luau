--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local StudioTestService = game:GetService("StudioTestService")
local KRF = ReplicatedStorage.Packages.KRF

local ActorTypes = require(KRF.server.Actor.types)
local ServerNetworkingTypes = require(KRF.server.Networking.types)
local ReplicationTypes = require(KRF.server.Replication.types)
local SharedNetworkingTypes = require(KRF.shared.Networking.types)
local Schema: SharedNetworkingTypes.Schema = require(KRF.shared.Networking.Schema)
local ActorEntity = require(KRF.server.Actor.ActorEntity)
local Registry: ActorTypes.ActorRegistry = require(KRF.server.Actor.ActorRegistry)

local Domains: ReplicationTypes.InternalReplicationDomainRegistry =
	require(KRF.server.Replication.ReplicationDomainRegistry)

local Networking: ServerNetworkingTypes.ServerNetworking = require(KRF.server.Networking.ServerNetworking)
local Publication: ServerNetworkingTypes.PublicationRuntimeModule = require(KRF.server.Networking.PublicationRuntime)

local Awareness: ServerNetworkingTypes.ActorAwarenessRuntimeModule =
	require(KRF.server.Networking.ActorAwarenessRuntime)

local NativeAssociation: ServerNetworkingTypes.PlayerAssociationModule =
	require(KRF.server.Networking.utils.NativePlayerAssociation)

local Handshake: ServerNetworkingTypes.ServerHandshakeModule = require(KRF.server.Networking.ServerHandshake)
local Codec: SharedNetworkingTypes.ActorStreamCodecModule = require(KRF.shared.Networking.ActorStreamCodec)
local ProtocolCodec: SharedNetworkingTypes.ProtocolCodec = require(KRF.shared.Networking.ProtocolCodec)
local Constants = require(KRF.shared.Networking.utils.ProtocolConstants)

Players.CharacterAutoLoads = false

local finished: boolean = false
local source: ServerNetworkingTypes.PlayerAssociationSource? = nil
local runtime: ServerNetworkingTypes.ActorAwarenessRuntime? = nil
local publication: ServerNetworkingTypes.PublicationRuntime? = nil
local handshake: ServerNetworkingTypes.ServerHandshake? = nil
local actors: { ActorTypes.Actor } = {}
local models: { Model } = {}
local owner: Player? = nil
local snapshots: number = 0

local function cleanup(): ()
	if runtime ~= nil then
		runtime:Destroy()
	end

	if source ~= nil then
		source.Destroy()
	end

	if handshake ~= nil then
		handshake:Destroy()
	end

	if publication ~= nil then
		publication:Destroy()
	end

	if owner ~= nil then
		owner.Character = nil
	end

	for _, actor: ActorTypes.Actor in actors do
		Registry.UnbindModel(actor)
	end

	for _, model: Model in models do
		model:Destroy()
	end

	Networking.Destroy()
end

local function finish(success: boolean, reason: string?): ()
	if finished then
		return
	end

	finished = true
	local cleaned: boolean, cleanupReason: any = pcall(cleanup)

	StudioTestService:EndTest({
		success = success and cleaned,
		reason = reason or (if cleaned then nil else tostring(cleanupReason)),
		snapshots = snapshots,
	})
end

task.delay(20, function(): ()
	finish(false, "Native Character association timeout")
end)

local function newModel(): Model
	local model: Model = Instance.new("Model")
	model.Parent = workspace
	table.insert(models, model)

	return model
end

local function run(): ()
	while #Players:GetPlayers() < 2 do
		Players.PlayerAdded:Wait()

		if finished then
			return
		end
	end

	local connected: { Player } = Players:GetPlayers()
	local player: Player = connected[1]
	owner = player
	local other: Player = connected[2]

	local definitions: { ReplicationTypes.ReplicationDomainDefinition } = {
		{
			id = "Game.Public",
			state = Schema.U8,
			snapshot = function(_actor: ActorTypes.Actor): any
				snapshots += 1

				return 10
			end,
		},
		{
			id = "Game.Private",
			audience = "Owner",
			state = Schema.U8,
			snapshot = function(_actor: ActorTypes.Actor): any
				snapshots += 1

				return 20
			end,
		},
	}

	local catalog: ReplicationTypes.PreparedReplicationDomainCatalog?, catalogReason: string? =
		Domains.Prepare(definitions)

	assert(catalog ~= nil, catalogReason)
	local protocol: SharedNetworkingTypes.PreparedProtocol?, protocolReason: string? = Networking.Prepare(catalog)
	assert(protocol ~= nil, protocolReason)
	local schemas: SharedNetworkingTypes.ActorSchemaCatalog = {}

	for _, definition: ReplicationTypes.LoadedReplicationDomainDefinition in catalog.orderedDefinitions do
		schemas[definition.id] = definition.state
	end

	local codec: SharedNetworkingTypes.ActorStreamCodec = Codec.Compile(protocol.runtime, schemas)
	local canonical: ServerNetworkingTypes.PublicationRuntime = Publication.new(catalog)
	publication = canonical
	local oldModel: Model = newModel()
	local newCharacter: Model = newModel()

	for _, model: Model in { oldModel, newCharacter } do
		local actor: ActorTypes.Actor = ActorEntity.new()
		table.insert(actors, actor)
		local bound: boolean, bindReason: string? = Registry.BindModel(actor, model)
		assert(bound, bindReason)
		local attached: boolean, attachReason: string? = canonical:AttachActor(actor)
		assert(attached, attachReason)
		actor.enabled = true
	end

	-- These are actual engine-created Players and the actual Character property, not a fake signal.
	player.Character = oldModel

	local native: ServerNetworkingTypes.PlayerAssociationSource = NativeAssociation.new()
	source = native
	assert(native.GetPlayerFromCharacter(oldModel) == player, "Native source must resolve current Character")
	local deliveries: { [Player]: { buffer } } = { [player] = {}, [other] = {} }
	local capturing: boolean = false

	local connection: ServerNetworkingTypes.ServerHandshake = Handshake.new(protocol, {
		SendReliable = function(recipient: Player, payload: buffer): ()
			if capturing then
				table.insert(deliveries[recipient], payload)
			end
		end,
	})

	handshake = connection
	local faults: { ServerNetworkingTypes.ActorAwarenessFault } = {}

	local awareness: ServerNetworkingTypes.ActorAwarenessRuntime = Awareness.new(canonical, catalog, protocol.runtime, {
		IsClientReady = function(recipient: Player): boolean
			return connection:IsClientReady(recipient)
		end,
		ObserveClientReady = function(callback: (Player) -> ()): () -> ()
			return connection:ObserveClientReady(callback)
		end,
		ObserveClientClosed = function(callback: (Player) -> ()): () -> ()
			return connection:ObserveClientClosed(callback)
		end,
		SendReliable = function(recipient: Player, payload: buffer): (boolean, string?)
			return connection:Send(recipient, payload)
		end,
		GetPlayerFromCharacter = native.GetPlayerFromCharacter,
		ObserveAssociationChanged = native.ObserveAssociationChanged,
		ReportFault = function(fault: ServerNetworkingTypes.ActorAwarenessFault): ()
			table.insert(faults, fault)
		end,
	}, {
		maxBaselineBytes = 512,
		maxChunkBytes = 16,
		maxQueuedBytes = 512,
		maxEvents = 4,
		maxHandle = 4294967295,
		maxRevision = 4294967295,
	})

	runtime = awareness

	for _, recipient: Player in { player, other } do
		local hello: buffer?, helloReason: string? =
			ProtocolCodec.Encode({ kind = "Hello", version = Constants.PROTOCOL_VERSION })

		assert(hello ~= nil, helloReason)
		local ready: buffer?, readyReason: string? = ProtocolCodec.Encode({ kind = "Ready" })
		assert(ready ~= nil, readyReason)
		connection:Handle(recipient, hello)
		connection:Handle(recipient, ready)
		assert(connection:IsClientReady(recipient), "Expected native Player to complete real N2 handshake")
	end

	capturing = true

	local function drain(): ()
		for _ = 1, 32 do
			awareness:Step(256, 8)
		end
	end

	local function baseline(recipient: Player, handle: number): { [string]: SharedNetworkingTypes.ActorDomainTruth }
		local assembly: buffer? = nil
		local generation: number = 0
		local complete: boolean = false

		for _, payload: buffer in deliveries[recipient] do
			local records: { SharedNetworkingTypes.ActorStreamRecord }?, reason: string? = codec.Decode(payload)
			assert(records ~= nil, reason)

			for _, record: SharedNetworkingTypes.ActorStreamRecord in records do
				if record.handle ~= handle then
					continue
				end

				if record.kind == "BaselineBegin" then
					assembly = buffer.create(record.totalBytes)
					generation = record.generation
					complete = false
				elseif record.kind == "BaselineChunk" and record.generation == generation then
					assert(assembly ~= nil, "Chunk before Begin")
					buffer.copy(assembly, record.offset, record.bytes)
				elseif record.kind == "BaselineEnd" and record.generation == generation then
					complete = true
				end
			end
		end

		assert(complete and assembly ~= nil, "Expected complete replacement baseline")

		local domains: { [string]: SharedNetworkingTypes.ActorDomainTruth }?, reason: string? =
			codec.DecodeBaseline(assembly)

		assert(domains ~= nil, reason)

		return domains
	end

	drain()
	local oldHandle: number? = awareness:GetHandle(player, actors[1])
	local newHandle: number? = awareness:GetHandle(player, actors[2])
	assert(oldHandle ~= nil and newHandle ~= nil, "Expected both registered Character Actors to be aware")
	assert(baseline(player, oldHandle)["Game.Private"] ~= nil, "Initial Character must receive Owner truth")
	assert(baseline(player, newHandle)["Game.Private"] == nil, "Future Character must initially be public-only")
	deliveries = { [player] = {}, [other] = {} }
	player.Character = newCharacter
	task.wait()
	drain()

	assert(
		native.GetPlayerFromCharacter(oldModel) == nil and native.GetPlayerFromCharacter(newCharacter) == player,
		"Native source must reevaluate both sides of the real Character transition"
	)

	assert(awareness:GetActorForPlayer(player) == actors[2], "Player association did not follow Character")
	assert(awareness:GetPlayerForActor(actors[1]) == nil, "Previous Character retained its Player")
	assert(baseline(player, oldHandle)["Game.Private"] == nil, "Previous Character retained Owner truth")
	local privateTruth: SharedNetworkingTypes.ActorDomainTruth? = baseline(player, newHandle)["Game.Private"]
	assert(privateTruth ~= nil and privateTruth.value == 20, "New Character did not receive canonical Owner truth")
	assert(#deliveries[other] == 0, "Character reassociation replaced an unrelated recipient")
	deliveries = { [player] = {}, [other] = {} }
	local unregistered: Model = newModel()

	player.Character = unregistered
	task.wait()
	drain()
	assert(native.GetPlayerFromCharacter(unregistered) == player, "Real Character property did not change")
	assert(Registry.GetActorByModel(unregistered) == nil, "Unregistered test Character acquired an Actor")
	assert(awareness:GetActorForPlayer(player) == nil, "Unregistered Character created a stale Player association")
	assert(baseline(player, newHandle)["Game.Private"] == nil, "Old Owner truth survived an unregistered Character")
	assert(#canonical:GetAttachedActors() == 2, "Unregistered Character changed Actor awareness membership")
	assert(#deliveries[other] == 0 and #faults == 0, "Unregistered Character caused unrelated traffic or a fault")
	assert(snapshots == 4, "Character transition reran per-domain snapshots instead of canonical capture")
end

local success: boolean, reason: any = pcall(run)

if not finished then
	finish(success, if success then nil else tostring(reason))
end
