--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF

local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local ActorTypes = require(KRF.server.Actor.types)
local ServerNetworkingTypes = require(KRF.server.Networking.types)
local SharedNetworkingTypes = require(KRF.shared.Networking.types)
local TestUtils = require(script.Parent.Parent.Utils.Networking.AwarenessTestUtils)

local fixture: TestUtils.Fixture
local player: Player
local actor: ActorTypes.Actor

beforeEach(function()
	fixture = TestUtils.new()
	player = TestUtils.player(fixture)
	actor = TestUtils.actor(fixture, nil)
end)

afterEach(function()
	TestUtils.destroy(fixture)
end)

it("uses canonical N3 truth without calling snapshots again for Ready or replacement", function()
	fixture.publicDomain.value = 11
	fixture.publicDomain.callbacks[actor]()
	local calls: number = fixture.publicDomain.snapshotCalls
	local runtime: ServerNetworkingTypes.ActorAwarenessRuntime = TestUtils.start(fixture)
	TestUtils.ready(fixture, player)
	TestUtils.drain(fixture)
	local handle: number? = runtime:GetHandle(player, actor)
	assert(handle ~= nil, "Expected handle")
	expect(TestUtils.baseline(fixture, player, handle)).toEqual({ ["Game.Public"] = { value = 11 } })
	expect(runtime:RequestReplacementBaseline(player, handle, nil)).toBe(true)
	TestUtils.drain(fixture)
	expect(fixture.publicDomain.snapshotCalls).toBe(calls)
end)

it("captures synchronously with a matching fence and queues an immediate later commit after End", function()
	local runtime: ServerNetworkingTypes.ActorAwarenessRuntime = TestUtils.start(fixture)
	TestUtils.ready(fixture, player)
	fixture.publicDomain.value = 12
	fixture.publicDomain.callbacks[actor]({ { id = "Changed", payload = 12 } })
	TestUtils.drain(fixture)
	local handle: number? = runtime:GetHandle(player, actor)
	assert(handle ~= nil, "Expected handle")
	expect(TestUtils.baseline(fixture, player, handle)).toEqual({ ["Game.Public"] = { value = 10 } })
	local ended: boolean = false

	for _, record: SharedNetworkingTypes.ActorStreamRecord in TestUtils.records(fixture, player) do
		if record.kind == "BaselineEnd" then
			ended = true
		end

		if record.kind == "Commit" then
			expect(ended).toBe(true)
		end
	end

	local commits: { any } = TestUtils.kind(fixture, player, "Commit")
	expect(#commits).toBe(1)
	expect(commits[1].patches).toEqual({ { domainId = "Game.Public", patch = { kind = "Replace", value = 12 } } })
	expect(commits[1].events).toEqual({ { domainId = "Game.Public", eventId = "Changed", payload = 12 } })
end)

it("absorbs pre-awareness state into baseline without replaying pre-awareness events", function()
	fixture.publicDomain.value = 12
	fixture.publicDomain.callbacks[actor]({ { id = "Changed", payload = 12 } })
	local runtime: ServerNetworkingTypes.ActorAwarenessRuntime = TestUtils.start(fixture)
	TestUtils.ready(fixture, player)
	TestUtils.drain(fixture)
	local handle: number? = runtime:GetHandle(player, actor)
	assert(handle ~= nil, "Expected handle")
	expect(TestUtils.baseline(fixture, player, handle)).toEqual({ ["Game.Public"] = { value = 12 } })
	expect(TestUtils.kind(fixture, player, "Commit")).toEqual({})
end)

it("does not leave a yield gap between stream creation and fence installation", function()
	TestUtils.start(fixture)
	local original: typeof(fixture.publication.CaptureBaseline) = fixture.publication.CaptureBaseline
	local capturedSequence: number? = nil

	fixture.publication.CaptureBaseline = function(
		self,
		current: ActorTypes.Actor,
		publicOnly: boolean?
	): ServerNetworkingTypes.PublicationBaseline?
		local baseline: ServerNetworkingTypes.PublicationBaseline? = original(self, current, publicOnly)
		assert(baseline ~= nil, "Expected canonical capture")
		capturedSequence = baseline.sequence

		return baseline
	end

	local readyThread: thread = coroutine.create(function(): ()
		TestUtils.ready(fixture, player)
	end)

	local completed: boolean, reason: any = coroutine.resume(readyThread)
	expect(completed).toBe(true)
	expect(reason).toBeNil()
	expect(coroutine.status(readyThread)).toBe("dead")
	expect(capturedSequence).toBe(fixture.publication:GetActorSequence(actor))
	fixture.publicDomain.value = 13
	fixture.publicDomain.callbacks[actor]()
	TestUtils.drain(fixture)
	expect(#TestUtils.kind(fixture, player, "Commit")).toBe(1)
end)

it("reconstructs the exact bounded baseline across chunks with one matching generation", function()
	fixture.options.maxChunkBytes = 1

	local runtime: ServerNetworkingTypes.ActorAwarenessRuntime = TestUtils.start(fixture)
	TestUtils.ready(fixture, player)
	TestUtils.drain(fixture)
	local begins: { any } = TestUtils.kind(fixture, player, "BaselineBegin")
	local chunks: { any } = TestUtils.kind(fixture, player, "BaselineChunk")
	local ends: { any } = TestUtils.kind(fixture, player, "BaselineEnd")
	expect(#begins).toBe(1)
	expect(#chunks > 1).toBe(true)
	expect(#ends).toBe(1)
	local nextOffset: number = 0

	for _, chunk: any in chunks do
		expect(chunk.generation).toBe(begins[1].generation)
		expect(chunk.offset).toBe(nextOffset)
		expect(buffer.len(chunk.bytes) <= 1).toBe(true)
		nextOffset += buffer.len(chunk.bytes)
	end

	expect(nextOffset).toBe(begins[1].totalBytes)
	expect(ends[1].generation).toBe(begins[1].generation)
	local handle: number? = runtime:GetHandle(player, actor)
	assert(handle ~= nil, "Expected handle")
	expect(TestUtils.baseline(fixture, player, handle)).toEqual({ ["Game.Public"] = { value = 10 } })
end)

it("rejects a recipient baseline above the actual encoded limit with Actor and recipient context", function()
	fixture.options.maxBaselineBytes = 1
	TestUtils.start(fixture)
	TestUtils.ready(fixture, player)
	TestUtils.drain(fixture)
	expect(fixture.deliveries).toEqual({})
	expect(fixture.faults).toEqual({ { player = player, actorId = actor:GetId(), reason = "ActorBaselineTooLarge" } })
end)

it("deduplicates replacement requests and captures current truth in a newer generation", function()
	local runtime: ServerNetworkingTypes.ActorAwarenessRuntime = TestUtils.start(fixture)
	TestUtils.ready(fixture, player)
	TestUtils.drain(fixture)
	local first: any = TestUtils.kind(fixture, player, "BaselineBegin")[1]
	local previousEnd: any = TestUtils.kind(fixture, player, "BaselineEnd")[1]

	fixture.publicDomain.value = 14
	fixture.publicDomain.callbacks[actor]({ { id = "Changed", payload = 14 } })
	fixture.deliveries = {}
	local success: boolean, reason: string? = runtime:RequestReplacementBaseline(player, first.handle, "TestRecovery")
	expect(success).toBe(true)
	expect(reason).toBeNil()
	success, reason = runtime:RequestReplacementBaseline(player, first.handle, "Duplicate")
	expect(success).toBe(false)
	expect(reason).toBe("BaselineAlreadyPending")
	TestUtils.drain(fixture)
	local begins: { any } = TestUtils.kind(fixture, player, "BaselineBegin")
	local ends: { any } = TestUtils.kind(fixture, player, "BaselineEnd")
	expect(#begins).toBe(1)
	expect(begins[1].generation > first.generation).toBe(true)
	expect(ends[1].revision > previousEnd.revision).toBe(true)
	expect(TestUtils.baseline(fixture, player, first.handle)).toEqual({ ["Game.Public"] = { value = 14 } })
	expect(TestUtils.kind(fixture, player, "Commit")).toEqual({})
end)

it("marks an excessive event backlog discontinuous and recaptures without replaying old history", function()
	fixture.options.maxEvents = 2
	fixture.options.maxChunkBytes = 1

	local runtime: ServerNetworkingTypes.ActorAwarenessRuntime = TestUtils.start(fixture)
	TestUtils.ready(fixture, player)
	runtime:Step(256, 1)
	local firstGeneration: number = TestUtils.kind(fixture, player, "BaselineBegin")[1].generation

	for value: number = 11, 30 do
		fixture.publicDomain.value = value
		fixture.publicDomain.callbacks[actor]({ { id = "Changed", payload = value } })
	end

	TestUtils.drain(fixture)
	local begins: { any } = TestUtils.kind(fixture, player, "BaselineBegin")
	local ends: { any } = TestUtils.kind(fixture, player, "BaselineEnd")
	expect(#begins >= 2).toBe(true)
	expect(begins[#begins].generation > firstGeneration).toBe(true)

	for _, ended: any in ends do
		expect(ended.generation).never.toBe(firstGeneration)
	end

	local handle: number? = runtime:GetHandle(player, actor)
	assert(handle ~= nil, "Expected handle")
	expect(TestUtils.baseline(fixture, player, handle)).toEqual({ ["Game.Public"] = { value = 30 } })
	expect(TestUtils.kind(fixture, player, "Commit")).toEqual({})
end)

it("keeps every physical send within its byte budget and respects zero work budgets", function()
	local runtime: ServerNetworkingTypes.ActorAwarenessRuntime = TestUtils.start(fixture)
	TestUtils.ready(fixture, player)
	runtime:Step(0, 8)
	runtime:Step(256, 0)
	expect(fixture.deliveries).toEqual({})

	for _ = 1, 32 do
		runtime:Step(96, 2)
	end

	expect(#TestUtils.kind(fixture, player, "BaselineEnd")).toBe(1)

	for _, delivery: TestUtils.Delivery in fixture.deliveries do
		expect(buffer.len(delivery.payload) <= 96).toBe(true)
	end
end)

it("recaptures after byte pressure without retaining an unbounded state backlog", function()
	fixture.options.maxQueuedBytes = 1
	fixture.options.maxChunkBytes = 1

	local runtime: ServerNetworkingTypes.ActorAwarenessRuntime = TestUtils.start(fixture)
	TestUtils.ready(fixture, player)
	runtime:Step(256, 1)
	local original: any = TestUtils.kind(fixture, player, "BaselineBegin")[1]

	for value: number = 11, 30 do
		fixture.publicDomain.value = value
		fixture.publicDomain.callbacks[actor]()
	end

	TestUtils.drain(fixture)
	local begins: { any } = TestUtils.kind(fixture, player, "BaselineBegin")
	expect(begins[#begins].generation > original.generation).toBe(true)
	expect(TestUtils.baseline(fixture, player, original.handle)).toEqual({ ["Game.Public"] = { value = 30 } })
	expect(TestUtils.kind(fixture, player, "Commit")).toEqual({})
end)

it("does not starve another live Actor while this Actor's replacement is pending", function()
	local runtime: ServerNetworkingTypes.ActorAwarenessRuntime = TestUtils.start(fixture)
	TestUtils.ready(fixture, player)
	local other: ActorTypes.Actor = TestUtils.actor(fixture, nil)
	TestUtils.drain(fixture)
	local handle: number? = runtime:GetHandle(player, actor)
	assert(handle ~= nil, "Expected handle")
	fixture.deliveries = {}
	expect(runtime:RequestReplacementBaseline(player, handle, nil)).toBe(true)
	fixture.publicDomain.value = 15
	fixture.publicDomain.callbacks[other]()

	for _ = 1, 8 do
		runtime:Step(96, 1)
	end

	local commits: { any } = TestUtils.kind(fixture, player, "Commit")
	expect(#commits).toBe(1)
	expect(commits[1].handle).toBe(runtime:GetHandle(player, other))
end)
