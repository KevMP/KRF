--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local StudioTestService = game:GetService("StudioTestService")
local KRF = ReplicatedStorage.Packages.KRF
local ActorTypes = require(KRF.server.Actor.types)
local Types = require(KRF.server.Networking.types)
local ReplicationTypes = require(KRF.server.Replication.types)
local SharedTypes = require(KRF.shared.Networking.types)
local SignalTypes = require(KRF.shared.Signal.types)
local Server = require(KRF.server)
local Actors: ActorTypes.ActorRuntime = require(KRF.server.Actor.ActorRuntime)
local Networking: Types.ServerNetworking = require(KRF.server.Networking.ServerNetworking)
local Awareness: Types.ActorAwarenessRuntimeModule = require(KRF.server.Networking.ActorAwarenessRuntime)
local Resync: Types.ResyncRuntimeModule = require(KRF.server.Networking.ResyncRuntime)
local Schema: SharedTypes.Schema = require(KRF.shared.Networking.Schema)
local Codec: SharedTypes.ActorStreamCodecModule = require(KRF.shared.Networking.ActorStreamCodec)
local ResyncCodec = require(KRF.shared.Networking.utils.ResyncCodec)
local control: RemoteEvent = ReplicatedStorage:WaitForChild("ActorViewTestControl") :: RemoteEvent

Players.CharacterAutoLoads = false
local originalAwareness: typeof(Awareness.new) = Awareness.new
local originalResync: typeof(Resync.new) = Resync.new
local awareness: Types.ActorAwarenessRuntime? = nil
local actor: ActorTypes.Actor? = nil
local model: Model? = nil
local models: { Model } = {}
local owner: Player? = nil
local ready: { [Player]: boolean } = {}
local reports: { [Player]: boolean } = {}
local recoveryRequests: { [Player]: number } = {}
local rejectedRecovery: number = 0
local resyncControl: Types.ResyncRuntime? = nil
local current: number = 10
local committed: ReplicationTypes.ReplicationDomainOnCommitted? = nil
local phase: string = "Ready"
local finished: boolean = false
local codec: SharedTypes.ActorStreamCodec? = nil
local faultInjected: boolean = false
local expectedRemoval: boolean = false
local lifecycleConnection: SignalTypes.Connection? = nil

-- Observe the production factories without replacing transports, Player identity,
-- the native installers, runtime behavior, or the client-to-server request path.
Awareness.new = function(
	publication: Types.PublicationRuntime,
	catalog: ReplicationTypes.PreparedReplicationDomainCatalog,
	protocol: SharedTypes.ClientProtocol,
	dependencies: Types.ActorAwarenessDependencies,
	options: Types.ActorAwarenessOptions
): Types.ActorAwarenessRuntime
	local bounded: Types.ActorAwarenessOptions = table.clone(options)
	bounded.maxRevision = 5
	local created: Types.ActorAwarenessRuntime =
		originalAwareness(publication, catalog, protocol, dependencies, bounded)
	awareness = created
	local schemas: SharedTypes.ActorSchemaCatalog = {}
	for _, definition in catalog.orderedDefinitions do
		schemas[definition.id] = definition.state
	end
	codec = Codec.Compile(protocol, schemas)
	return created
end
Resync.new = function(dependencies: Types.ResyncDependencies, options: Types.ResyncOptions): Types.ResyncRuntime
	local bounded: Types.ResyncOptions = table.clone(options)
	bounded.maxRequestsPerClient = 1
	local created: Types.ResyncRuntime = originalResync(dependencies, bounded)
	resyncControl = created
	local handle: typeof(created.Handle) = created.Handle
	created.Handle = function(self: Types.ResyncRuntime, player: Player, payload: any, ...: any): (boolean, string?)
		local accepted: boolean, reason: string? = handle(self, player, payload, ...)
		if accepted then
			recoveryRequests[player] = (recoveryRequests[player] or 0) + 1
		elseif reason == "ResyncRateLimited" then
			rejectedRecovery += 1
		end
		return accepted, reason
	end
	return created
end

local function finish(success: boolean, reason: string?): ()
	if finished then
		return
	end
	finished = true
	local cleaned: boolean, cleanupReason: any = pcall(function()
		if actor ~= nil then
			Actors.UnregisterActor(actor)
		end
		Networking.Destroy()
		if owner ~= nil then
			owner.Character = nil
		end
		for _, ownedModel: Model in models do
			ownedModel:Destroy()
		end
	end)
	Awareness.new = originalAwareness
	Resync.new = originalResync
	if lifecycleConnection ~= nil then
		lifecycleConnection:Disconnect()
	end
	StudioTestService:EndTest({
		success = success and cleaned,
		reason = reason or (if cleaned then nil else tostring(cleanupReason)),
		phase = phase,
		faultInjected = faultInjected,
		ownerRecoveryRequests = if owner ~= nil then recoveryRequests[owner] or 0 else 0,
		rejectedRecovery = rejectedRecovery,
	})
end

lifecycleConnection = Actors.OnActorUnregistering:Connect(function(removing: ActorTypes.Actor, reason: string?)
	if removing == actor and not finished and not expectedRemoval then
		finish(false, "Native Actor removed before test teardown: " .. tostring(reason))
	end
end)

local function sendPhase(nextPhase: string): ()
	phase = nextPhase
	reports = {}
	assert(actor ~= nil, "Expected registered native Actor")
	for player: Player in ready do
		control:FireClient(
			player,
			buffer.fromstring(
				HttpService:JSONEncode({ phase = phase, actorId = actor:GetId(), owner = player == owner })
			)
		)
	end
end

local function newCharacter(): Model
	local created: Model = Instance.new("Model")
	created.Name = "NativeActorViewSubject"
	-- A stable minimal Character keeps engine avatar/physics cleanup separate
	-- from the explicit Actor lifetime exercised by this fixture.
	local rootPart: Part = Instance.new("Part")
	rootPart.Name = "HumanoidRootPart"
	rootPart.Anchored = true
	rootPart.CFrame = CFrame.new(0, 20, 0)
	rootPart.Parent = created
	created.PrimaryPart = rootPart
	local humanoid: Humanoid = Instance.new("Humanoid")
	humanoid.RequiresNeck = false
	humanoid.Parent = created
	created.Parent = workspace
	table.insert(models, created)
	return created
end

local function begin(): ()
	local connected: { Player } = Players:GetPlayers()
	assert(#connected == 2, "Expected two real native clients")
	owner = connected[1]
	local created: Model = newCharacter()
	model = created
	owner.Character = created
	local registered: ActorTypes.Actor?, reason: string? = Actors.RegisterActor(created)
	assert(registered ~= nil, reason)
	actor = registered
	sendPhase("Initial")
end

local function advance(): ()
	assert(actor ~= nil and owner ~= nil and model ~= nil, "Expected native Actor/Owner")
	if phase == "Initial" then
		assert(committed ~= nil, "Expected real N3 committed observer")
		current = 20
		committed({ { id = "Changed", payload = 20 } })
		sendPhase("Live")
	elseif phase == "Live" then
		assert(
			awareness ~= nil and codec ~= nil and committed ~= nil and resyncControl ~= nil,
			"Expected real server pipeline"
		)
		local handle: number? = awareness:GetHandle(owner, actor)
		assert(handle ~= nil, "Expected native recipient handle")
		-- Spend this test connection's deliberately narrow admission window on an
		-- unknown handle. Real client requests must be rejected until it resets.
		local precharge: buffer?, prechargeReason: string? = ResyncCodec.Encode(4294967295)
		assert(precharge ~= nil, prechargeReason)
		local admitted: boolean, admissionReason: string? = resyncControl:Handle(owner, precharge)
		assert(not admitted and admissionReason == "UnknownActorHandle", "Expected admission precharge")
		-- Inject a structurally valid, deliberately discontinuous revision through
		-- the actual framework Reliable transport. No receiver or request is mocked.
		-- Seal current truth first; replacement must recover it without replaying history.
		current = 30
		committed()
		local payload: buffer?, reason: string? =
			codec.Encode({ { kind = "Commit", handle = handle, revision = 4294967295, patches = {}, events = {} } })
		assert(payload ~= nil, reason)
		local sent: boolean
		sent, reason = Networking.SendReliable(owner, payload)
		assert(sent, reason)
		faultInjected = true
		sendPhase("Recovery")
	elseif phase == "Recovery" then
		assert(recoveryRequests[owner] == 1, "Expected exactly one real owner resync round trip")
		assert(rejectedRecovery >= 1, "Native recovery did not exercise real rate-limit rejection")
		for player: Player in ready do
			if player ~= owner then
				assert((recoveryRequests[player] or 0) == 0, "Other client unexpectedly recovered")
			end
		end
		assert(committed ~= nil, "Expected committed observer")
		-- Force genuine server counter exhaustion under a narrow fixture limit.
		-- Semantic boundaries prevent coalescing these four revisions into one.
		for value: number = 40, 70, 10 do
			current = value
			committed({ { id = "Changed", payload = value } })
		end
		sendPhase("Halt")
	elseif phase == "Halt" then
		expectedRemoval = true
		local removed: boolean, reason: string? = Actors.UnregisterActor(actor)
		assert(removed, reason)
		sendPhase("Removed")
	elseif phase == "Removed" then
		-- Character reassignment removes the old engine Model. Exercise the
		-- supported respawn lifetime, after authoritative retirement of its Actor.
		local created: Model = newCharacter()
		model = created
		owner.Character = created
		task.wait()
		local registered: ActorTypes.Actor?, reason: string? = Actors.RegisterActor(created)
		assert(registered ~= nil, reason)
		actor = registered
		expectedRemoval = false
		sendPhase("Respawn")
	elseif phase == "Respawn" then
		sendPhase("Reset")
	elseif phase == "Reset" then
		finish(true, nil)
	else
		error("Unexpected native test phase: " .. phase, 0)
	end
end

control.OnServerEvent:Connect(function(player: Player, payload: any)
	if finished then
		return
	end
	local completed: boolean, reason: any = pcall(function()
		assert(typeof(payload) == "buffer", "Expected buffer test report")
		local report: any = HttpService:JSONDecode(buffer.tostring(payload))
		if report.failure ~= nil then
			error("Client " .. player.Name .. ": " .. tostring(report.failure), 0)
		end
		assert(report.phase == phase, "Client reported an unexpected phase")
		assert(not reports[player], "Duplicate native test report")
		if phase == "Ready" then
			assert(Networking.IsClientReady(player), "Client.Init returned before server readiness")
			ready[player] = true
		else
			assert(ready[player] == true, "Unknown native client")
		end
		reports[player] = true
		local count: number = 0
		for _ in reports do
			count += 1
		end
		if count == 2 then
			if phase == "Ready" then
				begin()
			else
				advance()
			end
		end
	end)
	if not completed then
		finish(false, tostring(reason))
	end
end)

task.delay(60, function()
	finish(false, "Native N5 fixture timeout in " .. phase)
end)
local initialized: boolean, failure: Server.StartupFailure? = Server.Init({
	replicationDomains = {
		{
			id = "Game.NativeOwner",
			audience = "Owner",
			state = Schema.Struct({ secret = Schema.String(16) }),
			snapshot = function(_actor: ActorTypes.Actor): any
				return { secret = "owner-only" }
			end,
		},
		{
			id = "Game.NativeState",
			state = Schema.Struct({ current = Schema.U16 }),
			events = { { id = "Changed", payload = Schema.U16 } },
			snapshot = function(_actor: ActorTypes.Actor): any
				return { current = current }
			end,
			observe = function(
				_actor: ActorTypes.Actor,
				callback: ReplicationTypes.ReplicationDomainOnCommitted
			): (() -> ())?
				committed = callback
				return function()
					committed = nil
				end
			end,
		},
	},
})
if not initialized then
	finish(false, if failure ~= nil then failure.reason else "Native Server.Init failed")
end
