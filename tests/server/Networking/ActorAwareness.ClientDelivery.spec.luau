--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local ActorTypes = require(KRF.server.Actor.types)
local Types = require(KRF.server.Networking.AwarenessTypes)
local ClientTypes = require(KRF.client.Networking.ActorStreamTypes)
local PublicationTypes = require(KRF.server.Networking.PublicationTypes)
local ProtocolTypes = require(KRF.shared.Networking.ProtocolTypes)
local WireTypes = require(KRF.shared.Networking.ActorStreamTypes)
local SchemaTypes = require(KRF.shared.Networking.types)
local Schema: SchemaTypes.Schema = require(KRF.shared.Networking.Schema)
local Publication: PublicationTypes.RuntimeModule = require(KRF.server.Networking.PublicationRuntime)
local Networking = require(KRF.server.Networking.ServerNetworking)
local Codec: WireTypes.CodecModule = require(KRF.shared.Networking.ActorStreamCodec)
local Constants = require(KRF.shared.Networking.ActorProtocolConstants)
local TestUtils = require(script.Parent.Parent.Utils.Networking.AwarenessTestUtils)
local ClientUtils = require(script.Parent.Parent.Parent.client.Utils.ActorStreamTestUtils)
local DomainUtils = require(script.Parent.Parent.Utils.Replication.ReplicationDomainTestUtils)

local fixture: TestUtils.Fixture
local client: ClientUtils.Fixture
local player: Player
beforeEach(function()
	fixture = TestUtils.new()
	client = ClientUtils.new()
	player = TestUtils.player(fixture)
	fixture.options.maxBaselineBytes = Constants.MAX_BASELINE_BYTES
	fixture.options.maxChunkBytes = Constants.CHUNK_BYTES
	fixture.options.maxQueuedBytes = Constants.MAX_QUEUED_BYTES
	fixture.options.maxEvents = Constants.MAX_EVENTS
	client.options.maxBaselineBytes = Constants.MAX_BASELINE_BYTES
	client.options.maxPendingBaselines = Constants.MAX_PENDING_BASELINES
end)
afterEach(function()
	ClientUtils.destroy(client)
	TestUtils.destroy(fixture)
end)

local function connect(): Types.Runtime
	client.codec = fixture.codec
	local receiver: ClientTypes.Runtime = ClientUtils.start(client)
	fixture.dependencies.SendReliable = function(recipient: Player, payload: buffer): (boolean, string?)
		table.insert(fixture.deliveries, { player = recipient, payload = payload })
		local accepted: boolean, reason: string? = receiver:Handle(payload)
		expect(reason).toBeNil()
		expect(accepted).toBe(true)
		return true, nil
	end
	local runtime: Types.Runtime = TestUtils.start(fixture)
	TestUtils.ready(fixture, player)
	return runtime
end

local function drain(runtime: Types.Runtime): ()
	for _ = 1, 64 do
		runtime:Step(Constants.STEP_BYTES, Constants.STEP_RECORDS)
	end
end

it("delivers more Actors than the production client can assemble concurrently", function()
	local actors: { ActorTypes.Actor } = {}
	for _ = 1, Constants.MAX_PENDING_BASELINES + 9 do
		table.insert(actors, TestUtils.actor(fixture, nil))
	end
	local runtime: Types.Runtime = connect()
	drain(runtime)
	expect(#client.baselines).toBe(#actors)
	expect(client.faults).toEqual({})
	expect(fixture.faults).toEqual({})
	for _, actor: ActorTypes.Actor in actors do
		assert(client.runtime ~= nil, "Expected connected receiver")
		local record: ClientTypes.ActorRecord? = client.runtime:GetByActorId(actor:GetId())
		assert(record ~= nil, "Every Actor must establish an identity")
		expect(record.handle).toBe(runtime:GetHandle(player, actor))
	end
end)

it("recovers a valid live update larger than a production step through a chunked baseline", function()
	fixture.publication:Destroy()
	fixture.publicDomain.definition.state = Schema.String(50000)
	fixture.publicDomain.value = "initial"
	fixture.catalog = DomainUtils.prepare({ fixture.publicDomain.definition, fixture.ownerDomain.definition })
	local protocol: ProtocolTypes.PreparedProtocol?, reason: string? = Networking.Prepare(fixture.catalog)
	expect(reason).toBeNil()
	assert(protocol ~= nil, "Expected string-state protocol")
	fixture.protocol = protocol
	fixture.publication = Publication.new(fixture.catalog)
	local schemas: WireTypes.SchemaCatalog = {}
	for id, definition in fixture.catalog.definitionsById do
		schemas[id] = definition.state
	end
	fixture.codec = Codec.Compile(protocol.runtime, schemas)
	local actor: ActorTypes.Actor = TestUtils.actor(fixture, nil)
	local runtime: Types.Runtime = connect()
	drain(runtime)
	local large: string = string.rep("x", 40000)
	local measured: number? = fixture.codec.Measure({
		{
			kind = "Commit",
			handle = 1,
			revision = 2,
			patches = { { domainId = "Game.Public", patch = { kind = "Replace", value = large } } },
			events = { { domainId = "Game.Public", eventId = "Changed", payload = 7 } },
		},
	})
	assert(measured ~= nil, "Expected valid large live record")
	expect(measured > Constants.STEP_BYTES).toBe(true)
	expect(measured < Constants.MAX_PACKET_BYTES).toBe(true)
	fixture.publicDomain.value = large
	fixture.publicDomain.callbacks[actor]({ { id = "Changed", payload = 7 } })
	drain(runtime)
	expect(#client.baselines).toBe(2)
	expect(client.baselines[2].domains["Game.Public"].value).toBe(large)
	expect(client.baselines[2].revision).toBe(2)
	expect(client.commits).toEqual({})
	fixture.publicDomain.value = "after recovery"
	fixture.publicDomain.callbacks[actor]({ { id = "Changed", payload = 8 } })
	drain(runtime)
	expect(#client.commits).toBe(1)
	expect(client.commits[1].revision).toBe(3)
	expect(client.commits[1].events).toEqual({ { domainId = "Game.Public", eventId = "Changed", payload = 8 } })
	expect(client.faults).toEqual({})
	expect(fixture.faults).toEqual({})
end)

it("releases reservations for failed initial sends so later Actors can establish", function()
	for _ = 1, Constants.MAX_PENDING_BASELINES + 3 do
		TestUtils.actor(fixture, nil)
	end
	local runtime: Types.Runtime = connect()
	local send: typeof(fixture.dependencies.SendReliable) = fixture.dependencies.SendReliable
	local first: boolean = true
	fixture.dependencies.SendReliable = function(recipient: Player, payload: buffer): (boolean, string?)
		if first then
			first = false
			return false, "ForcedSendFailure"
		end
		return send(recipient, payload)
	end
	drain(runtime)
	expect(#client.baselines).toBe(3)
	expect(#fixture.faults).toBe(Constants.MAX_PENDING_BASELINES)
	expect(client.faults).toEqual({})
end)

it("retains occupied slots after faults until successful removal releases the client assembly", function()
	local actors: { ActorTypes.Actor } = {}
	for _ = 1, Constants.MAX_PENDING_BASELINES + 1 do
		table.insert(actors, TestUtils.actor(fixture, nil))
	end
	fixture.options.maxRevision = 0
	local runtime: Types.Runtime = connect()
	drain(runtime)
	expect(#TestUtils.kind(fixture, player, "BaselineBegin")).toBe(Constants.MAX_PENDING_BASELINES)
	expect(#fixture.faults).toBe(Constants.MAX_PENDING_BASELINES)
	fixture.options.maxRevision = Constants.MAX_COUNTER
	runtime:OnActorUnregistering(actors[1])
	drain(runtime)
	expect(#client.removed).toBe(1)
	expect(#client.baselines).toBe(1)
	expect(client.faults).toEqual({})
end)

it("keeps an incomplete assembly slot across overload recapture", function()
	fixture.options.maxEvents = 1
	local actor: ActorTypes.Actor = TestUtils.actor(fixture, nil)
	for _ = 1, Constants.MAX_PENDING_BASELINES + 2 do
		TestUtils.actor(fixture, nil)
	end
	local runtime: Types.Runtime = connect()
	runtime:Step(Constants.STEP_BYTES, Constants.STEP_RECORDS)
	fixture.publicDomain.callbacks[actor]({ { id = "Changed", payload = 1 } })
	fixture.publicDomain.value = 12
	fixture.publicDomain.callbacks[actor]({ { id = "Changed", payload = 2 } })
	drain(runtime)
	expect(#client.baselines).toBe(Constants.MAX_PENDING_BASELINES + 3)
	expect(client.commits).toEqual({})
	expect(client.faults).toEqual({})
	expect(fixture.faults).toEqual({})
end)

it("preserves admission and generation changes made reentrantly while Begin and End are sent", function()
	local actor: ActorTypes.Actor = TestUtils.actor(fixture, nil)
	for _ = 1, Constants.MAX_PENDING_BASELINES + 2 do
		TestUtils.actor(fixture, nil)
	end
	local runtime: Types.Runtime = connect()
	local send: typeof(fixture.dependencies.SendReliable) = fixture.dependencies.SendReliable
	local began: boolean = false
	local ended: boolean = false
	fixture.dependencies.SendReliable = function(recipient: Player, payload: buffer): (boolean, string?)
		local accepted: boolean, reason: string? = send(recipient, payload)
		local records: { WireTypes.Record }? = fixture.codec.Decode(payload)
		assert(records ~= nil, "Expected decoded delivery")
		for _, record: WireTypes.Record in records do
			if record.handle == runtime:GetHandle(player, actor) then
				if record.kind == "BaselineBegin" and not began then
					began = true
					TestUtils.associate(fixture, actor, player)
				elseif record.kind == "BaselineEnd" and not ended then
					ended = true
					TestUtils.associate(fixture, actor, nil)
				end
			end
		end
		runtime:Step(Constants.STEP_BYTES, Constants.STEP_RECORDS)
		return accepted, reason
	end
	drain(runtime)
	expect(began).toBe(true)
	expect(ended).toBe(true)
	expect(#client.baselines).toBe(Constants.MAX_PENDING_BASELINES + 4)
	expect(client.faults).toEqual({})
	expect(fixture.faults).toEqual({})
end)
