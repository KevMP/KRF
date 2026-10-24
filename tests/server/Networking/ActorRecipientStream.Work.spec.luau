--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local Types = require(KRF.server.Networking.types)
local ActorTypes = require(KRF.server.Actor.types)
local Streams = require(KRF.server.Networking.utils.ActorRecipientStream)
local Budget = require(KRF.server.Networking.utils.ReliableWorkBudget)
local TestUtils = require(script.Parent.Parent.Utils.Networking.AwarenessTestUtils)
local fixture: TestUtils.Fixture
local runtime: Types.ActorAwarenessRuntime
local player: Player
local actor: ActorTypes.Actor
local stream: Streams.Stream

beforeEach(function()
	fixture = TestUtils.new()
	player = TestUtils.player(fixture)
	actor = TestUtils.actor(fixture, nil)
	runtime = TestUtils.start(fixture)
	TestUtils.ready(fixture, player)
	stream = (runtime :: any).connections[player].actors[actor]
end)

afterEach(function()
	TestUtils.destroy(fixture)
end)

for _, unit: string in { "prepares", "checks" } do
	it("refuses preparation before changing stream state when " .. unit .. " work is exhausted", function()
		local work = Budget.new(4, { [unit] = 0 })
		local generation = stream.generation
		local record = stream:Prepare(512, true, 512, 0, work)
		expect(record).toBeNil()
		expect(stream.generation).toBe(generation)
		expect(#fixture.deliveries).toBe(0)
		TestUtils.drain(fixture)
		expect(#TestUtils.kind(fixture, player, "BaselineEnd")).toBe(1)
	end)
end

it("keeps discontinuous work pending when capture work is unavailable", function()
	TestUtils.drain(fixture)

	for value = 11, 16 do
		fixture.publicDomain.value = value
		fixture.publicDomain.callbacks[actor]({ { id = "Changed", payload = value } })
	end

	local generation = stream.generation
	local work = Budget.new(4, { captures = 0 })
	expect(stream:Prepare(512, true, 512, nil, work)).toBeNil()
	expect(stream.generation).toBe(generation)
	expect(stream.recapture).toBe(true)
	expect(work.used.captures).toBe(0)
	TestUtils.drain(fixture)
	expect(#TestUtils.kind(fixture, player, "BaselineEnd")).toBe(2)
end)

it("halts a detached replacement without inventing baseline truth or retaining failed work", function()
	TestUtils.drain(fixture)

	for value = 11, 16 do
		fixture.publicDomain.value = value
		fixture.publicDomain.callbacks[actor]({ { id = "Changed", payload = value } })
	end

	fixture.publication:DetachActor(actor)
	local work = Budget.new(4)
	expect(stream:Prepare(512, true, 512, nil, work)).toBeNil()
	expect(fixture.faults[1].reason).toBe("ActorBaselineMissing")
	TestUtils.drain(fixture)
	expect(stream:Prepare(512, true, 512, nil, Budget.new(4))).toBeNil()
	expect(#TestUtils.kind(fixture, player, "ActorHalt")).toBe(1)
end)

it("halts exhausted live revisions before draining authoritative event history", function()
	fixture.options.maxRevision = 1
	TestUtils.drain(fixture)
	fixture.publicDomain.value = 11
	fixture.publicDomain.callbacks[actor]({ { id = "Changed", payload = 11 } })
	TestUtils.drain(fixture)
	expect(fixture.faults[1].reason).toBe("ActorRevisionExhausted")
	expect(#TestUtils.kind(fixture, player, "Commit")).toBe(0)
	expect(#TestUtils.kind(fixture, player, "ActorHalt")).toBe(1)
end)
