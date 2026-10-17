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

local function drain(runtime: Types.Runtime, budget: number?): ()
	for _ = 1, 64 do
		runtime:Step(budget or Constants.STEP_BYTES, Constants.STEP_RECORDS)
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

for _, delivery: { budget: number, size: number, recover: boolean } in
	{
		{ budget = 2048, size = 4000, recover = true },
		{ budget = Constants.STEP_BYTES, size = 40000, recover = true },
		{ budget = Constants.MAX_PACKET_BYTES, size = 40000, recover = false },
	}
do
	it("delivers live work under a sustained byte budget of " .. tostring(delivery.budget), function()
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
		local large: string = string.rep("x", delivery.size)
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
		expect(measured > delivery.budget).toBe(delivery.recover)
		expect(measured < Constants.MAX_PACKET_BYTES).toBe(true)
		fixture.publicDomain.value = large
		fixture.publicDomain.callbacks[actor]({ { id = "Changed", payload = 7 } })
		-- A single small pass must preserve events if the next pass can carry them.
		runtime:Step(2048, Constants.STEP_RECORDS)
		expect(#client.baselines).toBe(1)
		expect(client.commits).toEqual({})
		drain(runtime, delivery.budget)
		if delivery.recover then
			expect(#client.baselines).toBe(2)
			expect(client.baselines[2].domains["Game.Public"].value).toBe(large)
			expect(client.baselines[2].revision).toBe(2)
			expect(client.commits).toEqual({})
		else
			expect(#client.baselines).toBe(1)
			expect(#client.commits).toBe(1)
			expect(client.commits[1].revision).toBe(2)
			expect(client.commits[1].patches[1].patch).toEqual({ kind = "Replace", value = large })
			expect(client.commits[1].events).toEqual({ { domainId = "Game.Public", eventId = "Changed", payload = 7 } })
		end
		client.commits = {}
		fixture.publicDomain.value = "after recovery"
		fixture.publicDomain.callbacks[actor]({ { id = "Changed", payload = 8 } })
		drain(runtime, delivery.budget)
		expect(#client.commits).toBe(1)
		expect(client.commits[1].revision).toBe(3)
		expect(client.commits[1].events).toEqual({ { domainId = "Game.Public", eventId = "Changed", payload = 8 } })
		expect(client.faults).toEqual({})
		expect(fixture.faults).toEqual({})
	end)
end

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

for _, faultSource: string in { "revision", "send" } do
	it("reliably cleans terminal " .. faultSource .. " faults before admitting unrelated Actors", function()
		local actors: { ActorTypes.Actor } = {}
		for _ = 1, Constants.MAX_PENDING_BASELINES do
			table.insert(actors, TestUtils.actor(fixture, nil))
		end
		if faultSource == "revision" then
			fixture.options.maxRevision = 0
		end
		local runtime: Types.Runtime = connect()
		local send: typeof(fixture.dependencies.SendReliable) = fixture.dependencies.SendReliable
		local allowCleanup: boolean = false
		local cleanupAttempts: number = 0
		fixture.dependencies.SendReliable = function(recipient: Player, payload: buffer): (boolean, string?)
			local records: { WireTypes.Record }? = fixture.codec.Decode(payload)
			assert(records ~= nil, "Expected valid delivery")
			for _, record: WireTypes.Record in records do
				if record.kind == "ActorHalt" then
					cleanupAttempts += 1
					if not allowCleanup then
						return false, "CleanupUnavailable"
					end
				elseif faultSource == "send" and not allowCleanup and record.kind == "BaselineChunk" then
					return false, "ChunkSendFailed"
				end
			end
			return send(recipient, payload)
		end
		drain(runtime)
		expect(#TestUtils.kind(fixture, player, "BaselineBegin")).toBe(Constants.MAX_PENDING_BASELINES)
		expect(#fixture.faults).toBe(Constants.MAX_PENDING_BASELINES)
		expect(cleanupAttempts > 0).toBe(true)
		expect(client.baselines).toEqual({})
		fixture.options.maxRevision = Constants.MAX_COUNTER
		local unrelated: ActorTypes.Actor = TestUtils.actor(fixture, nil)
		drain(runtime)
		expect(#TestUtils.kind(fixture, player, "BaselineBegin")).toBe(Constants.MAX_PENDING_BASELINES)
		allowCleanup = true
		drain(runtime)
		expect(#TestUtils.kind(fixture, player, "ActorHalt")).toBe(Constants.MAX_PENDING_BASELINES)
		expect(client.removed).toEqual({})
		expect(#client.baselines).toBe(1)
		expect(client.baselines[1].actor.actorId).toBe(unrelated:GetId())
		for _, actor: ActorTypes.Actor in actors do
			expect(actor.enabled).toBe(true)
			expect(runtime:IsAware(player, actor)).toBe(true)
		end
		fixture.publicDomain.value = 12
		fixture.publicDomain.callbacks[unrelated]()
		drain(runtime)
		expect(#client.commits).toBe(1)
		expect(client.commits[1].actor.actorId).toBe(unrelated:GetId())
		expect(#fixture.faults).toBe(Constants.MAX_PENDING_BASELINES)
		expect(client.faults).toEqual({})
	end)
end

it("cleans faults raised reentrantly before the initial Begin send returns", function()
	local actors: { ActorTypes.Actor } = {}
	for _ = 1, Constants.MAX_PENDING_BASELINES do
		table.insert(actors, TestUtils.actor(fixture, nil))
	end
	local unrelated: ActorTypes.Actor = TestUtils.actor(fixture, nil)
	local runtime: Types.Runtime = connect()
	local send: typeof(fixture.dependencies.SendReliable) = fixture.dependencies.SendReliable
	local faulted: boolean = false
	fixture.dependencies.SendReliable = function(recipient: Player, payload: buffer): (boolean, string?)
		local accepted: boolean, reason: string? = send(recipient, payload)
		if not faulted then
			faulted = true
			for _, actor: ActorTypes.Actor in actors do
				fixture.publication:DetachActor(actor)
				TestUtils.associate(fixture, actor, player)
			end
		end
		return accepted, reason
	end
	drain(runtime)
	expect(#fixture.faults).toBe(#actors)
	expect(#TestUtils.kind(fixture, player, "ActorHalt")).toBe(#actors)
	expect(#client.baselines).toBe(1)
	expect(client.baselines[1].actor.actorId).toBe(unrelated:GetId())
	expect(client.faults).toEqual({})
end)

it("retries removal of a known incomplete assembly until reliable cleanup succeeds", function()
	local actor: ActorTypes.Actor = TestUtils.actor(fixture, nil)
	local runtime: Types.Runtime = connect()
	runtime:Step(Constants.STEP_BYTES, Constants.STEP_RECORDS)
	local send: typeof(fixture.dependencies.SendReliable) = fixture.dependencies.SendReliable
	local attempts: number = 0
	fixture.dependencies.SendReliable = function(recipient: Player, payload: buffer): (boolean, string?)
		attempts += 1
		if attempts == 1 then
			return false, "RemovalUnavailable"
		end
		return send(recipient, payload)
	end
	runtime:OnActorUnregistering(actor)
	drain(runtime)
	expect(attempts).toBe(2)
	expect(#client.removed).toBe(1)
	expect(client.removed[1].actorId).toBe(actor:GetId())
	expect(#fixture.faults).toBe(1)
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
