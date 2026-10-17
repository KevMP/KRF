--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF

local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local expect: any = JestGlobals.expect
local ActorTypes = require(KRF.server.Actor.types)
local Types = require(KRF.server.Networking.AwarenessTypes)
local PublicationTypes = require(KRF.server.Networking.PublicationTypes)
local ReplicationTypes = require(KRF.server.Replication.types)
local ProtocolTypes = require(KRF.shared.Networking.ProtocolTypes)
local NetworkingTypes = require(KRF.server.Networking.types)
local WireTypes = require(KRF.shared.Networking.ActorStreamTypes)
local SchemaTypes = require(KRF.shared.Networking.types)
local Schema: SchemaTypes.Schema = require(KRF.shared.Networking.Schema)
local Runtime: Types.RuntimeModule = require(KRF.server.Networking.ActorAwarenessRuntime)
local Publication: PublicationTypes.RuntimeModule = require(KRF.server.Networking.PublicationRuntime)
local Codec: WireTypes.CodecModule = require(KRF.shared.Networking.ActorStreamCodec)
local ActorEntity = require(KRF.server.Actor.ActorEntity)
local Networking: NetworkingTypes.ServerNetworking = require(KRF.server.Networking.ServerNetworking)
local PublicationUtils = require(script.Parent.PublicationTestUtils)
local DomainUtils = require(script.Parent.Parent.Replication.ReplicationDomainTestUtils)
local ProtocolUtils = require(script.Parent.Parent.Parent.Parent.shared.Utils.Networking.ProtocolTestUtils)

export type Delivery = { player: Player, payload: buffer }
export type Fixture = {
	publication: PublicationTypes.Runtime,
	runtime: Types.Runtime?,
	protocol: ProtocolTypes.PreparedProtocol,
	catalog: ReplicationTypes.PreparedReplicationDomainCatalog,
	codec: WireTypes.Codec,
	publicDomain: PublicationUtils.DomainFixture,
	ownerDomain: PublicationUtils.DomainFixture,
	readyPlayers: { [Player]: boolean },
	owners: { [Model]: Player },
	deliveries: { Delivery },
	faults: { Types.Fault },
	readyObservers: { (Player) -> () },
	closedObservers: { (Player) -> () },
	associationObservers: { (Model) -> () },
	instances: { Instance },
	options: Types.Options,
	dependencies: Types.Dependencies,
}

local TestUtils = {}

function TestUtils.new(): Fixture
	local publicDomain: PublicationUtils.DomainFixture = PublicationUtils.createDomain("Game.Public", Schema.U8, 10)
	publicDomain.definition.events = { { id = "Changed", payload = Schema.U8 } }
	local ownerDomain: PublicationUtils.DomainFixture = PublicationUtils.createDomain("Game.Private", Schema.U8, 20)
	ownerDomain.definition.audience = "Owner"
	ownerDomain.definition.events = { { id = "Changed", payload = Schema.U8 } }
	local catalog: ReplicationTypes.PreparedReplicationDomainCatalog =
		DomainUtils.prepare({ publicDomain.definition, ownerDomain.definition })
	local protocol: ProtocolTypes.PreparedProtocol?, reason: string? = Networking.Prepare(catalog)
	expect(reason).toBeNil()
	assert(protocol ~= nil, "Expected N2 protocol")
	local schemas: WireTypes.SchemaCatalog = {}
	for _, definition: ReplicationTypes.LoadedReplicationDomainDefinition in catalog.orderedDefinitions do
		schemas[definition.id] = definition.state
	end
	local fixture: Fixture = {
		publication = Publication.new(catalog),
		runtime = nil,
		protocol = protocol,
		catalog = catalog,
		codec = Codec.Compile(protocol.runtime, schemas),
		publicDomain = publicDomain,
		ownerDomain = ownerDomain,
		readyPlayers = {},
		owners = {},
		deliveries = {},
		faults = {},
		readyObservers = {},
		closedObservers = {},
		associationObservers = {},
		instances = {},
		options = {
			maxBaselineBytes = 512,
			maxChunkBytes = 16,
			maxQueuedBytes = 512,
			maxEvents = 4,
			maxHandle = 4294967295,
			maxRevision = 4294967295,
		},
		dependencies = {} :: Types.Dependencies,
	}
	fixture.dependencies = {
		IsClientReady = function(player: Player): boolean
			return fixture.readyPlayers[player] == true
		end,
		ObserveClientReady = function(callback: (Player) -> ()): () -> ()
			table.insert(fixture.readyObservers, callback)
			return function(): ()
				local index: number? = table.find(fixture.readyObservers, callback)
				if index ~= nil then
					table.remove(fixture.readyObservers, index)
				end
			end
		end,
		ObserveClientClosed = function(callback: (Player) -> ()): () -> ()
			table.insert(fixture.closedObservers, callback)
			return function(): ()
				local index: number? = table.find(fixture.closedObservers, callback)
				if index ~= nil then
					table.remove(fixture.closedObservers, index)
				end
			end
		end,
		SendReliable = function(player: Player, payload: buffer): (boolean, string?)
			table.insert(fixture.deliveries, { player = player, payload = payload })
			return true, nil
		end,
		GetPlayerFromCharacter = function(model: Model): Player?
			return fixture.owners[model]
		end,
		ObserveAssociationChanged = function(callback: (Model) -> ()): () -> ()
			table.insert(fixture.associationObservers, callback)
			return function(): ()
				local index: number? = table.find(fixture.associationObservers, callback)
				if index ~= nil then
					table.remove(fixture.associationObservers, index)
				end
			end
		end,
		ReportFault = function(fault: Types.Fault): ()
			table.insert(fixture.faults, fault)
		end,
	}
	return fixture
end

function TestUtils.start(fixture: Fixture): Types.Runtime
	local runtime: Types.Runtime = Runtime.new(
		fixture.publication,
		fixture.catalog,
		fixture.protocol.runtime,
		fixture.dependencies,
		fixture.options
	)
	fixture.runtime = runtime
	return runtime
end

function TestUtils.player(fixture: Fixture): Player
	local player: Player = ProtocolUtils.createPlayer()
	table.insert(fixture.instances, player)
	return player
end

function TestUtils.actor(fixture: Fixture, owner: Player?): ActorTypes.Actor
	local model: Model = Instance.new("Model")
	table.insert(fixture.instances, model)
	local actor: ActorTypes.Actor = ActorEntity.new(model)
	actor.enabled = true
	if owner ~= nil then
		fixture.owners[model] = owner
	end
	local attached: boolean, reason: string? = fixture.publication:AttachActor(actor)
	expect(attached).toBe(true)
	expect(reason).toBeNil()
	if fixture.runtime ~= nil then
		fixture.runtime:OnActorRegistered(actor)
	end
	return actor
end

function TestUtils.ready(fixture: Fixture, player: Player): ()
	fixture.readyPlayers[player] = true
	for _, callback: (Player) -> () in table.clone(fixture.readyObservers) do
		callback(player)
	end
end

function TestUtils.close(fixture: Fixture, player: Player): ()
	fixture.readyPlayers[player] = nil
	for _, callback: (Player) -> () in table.clone(fixture.closedObservers) do
		callback(player)
	end
end

function TestUtils.associate(fixture: Fixture, actor: ActorTypes.Actor, player: Player?): ()
	assert(actor.model ~= nil, "Expected Character Model")
	fixture.owners[actor.model] = player
	-- Publish the dependency event. The fixture never calls the runtime's refresh method.
	for _, callback: (Model) -> () in table.clone(fixture.associationObservers) do
		callback(actor.model)
	end
end

function TestUtils.records(fixture: Fixture, player: Player): { WireTypes.Record }
	local result: { WireTypes.Record } = {}
	for _, delivery: Delivery in fixture.deliveries do
		if delivery.player == player then
			expect(typeof(delivery.payload)).toBe("buffer")
			local records: { WireTypes.Record }?, reason: string? = fixture.codec.Decode(delivery.payload)
			expect(reason).toBeNil()
			assert(records ~= nil, "Expected decodable Actor packet")
			for _, record: WireTypes.Record in records do
				table.insert(result, record)
			end
		end
	end
	return result
end

function TestUtils.kind(fixture: Fixture, player: Player, kind: string): { any }
	local result: { any } = {}
	for _, record: WireTypes.Record in TestUtils.records(fixture, player) do
		if record.kind == kind then
			table.insert(result, record)
		end
	end
	return result
end

function TestUtils.drain(fixture: Fixture): ()
	assert(fixture.runtime ~= nil, "Expected awareness runtime")
	-- A fixed number of scheduler passes; no waits or dependence on frame timing.
	for _ = 1, 32 do
		fixture.runtime:Step(256, 8)
	end
end

function TestUtils.baseline(fixture: Fixture, player: Player, handle: number): { [string]: WireTypes.DomainTruth }
	local totalBytes: number = 0
	local generation: number = 0
	local assembled: buffer? = nil
	local ended: boolean = false
	for _, record: WireTypes.Record in TestUtils.records(fixture, player) do
		if record.handle ~= handle then
			continue
		end
		if record.kind == "BaselineBegin" then
			totalBytes = record.totalBytes
			generation = record.generation
			assembled = buffer.create(totalBytes)
			ended = false
		elseif record.kind == "BaselineChunk" and record.generation == generation then
			assert(assembled ~= nil, "Chunk requires Begin")
			expect(record.offset + buffer.len(record.bytes) <= totalBytes).toBe(true)
			buffer.copy(assembled, record.offset, record.bytes)
		elseif record.kind == "BaselineEnd" and record.generation == generation then
			ended = true
		end
	end
	expect(ended).toBe(true)
	assert(assembled ~= nil, "Expected baseline bytes")
	local domains: { [string]: WireTypes.DomainTruth }?, reason: string? = fixture.codec.DecodeBaseline(assembled)
	expect(reason).toBeNil()
	assert(domains ~= nil, "Expected decoded baseline")
	return domains
end

function TestUtils.destroy(fixture: Fixture): ()
	if fixture.runtime ~= nil then
		fixture.runtime:Destroy()
	end
	fixture.publication:Destroy()
	for _, instance: Instance in fixture.instances do
		instance:Destroy()
	end
	Networking._ResetForTests()
end

return TestUtils
