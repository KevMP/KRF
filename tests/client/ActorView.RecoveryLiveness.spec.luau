--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local PublicTypes = require(KRF.client.Actor.types)
local TestUtils = require(script.Parent.Utils.ActorViewTestUtils)

local fixture: TestUtils.Fixture
beforeEach(function()
	fixture = TestUtils.new()
end)
afterEach(function()
	TestUtils.destroy(fixture)
end)

it("retries a transient send failure and cancels its timer after synchronous replacement", function()
	TestUtils.destroy(fixture)
	local sends: number = 0
	fixture = TestUtils.new(function(_payload: buffer)
		sends += 1
		if sends == 1 then
			error("TransientSendFailure", 0)
		end
		TestUtils.baseline(fixture, 1, nil, 20, TestUtils.truth(50), 2)
	end)
	TestUtils.baseline(fixture)
	TestUtils.commit(fixture, 12)
	expect(sends).toBe(1)
	TestUtils.advance(fixture, 1)
	expect(sends).toBe(2)
	expect(TestUtils.domain(fixture):GetState().current).toBe(50)
	expect(TestUtils.view(fixture):IsAvailable()).toBe(true)
	expect(fixture.faults[2].reason).toBe("ResyncSendFailed:TransientSendFailure")
	TestUtils.advance(fixture, 100)
	expect(sends).toBe(2)
	TestUtils.commit(fixture, 21, { TestUtils.patch(40) })
	expect(TestUtils.domain(fixture):GetState().current).toBe(40)
end)

it("bounds silent rejection to five spaced requests then invalidates only the exhausted Actor", function()
	TestUtils.baseline(fixture)
	TestUtils.baseline(fixture, 2, "ActorB")
	local view: PublicTypes.ActorView = TestUtils.view(fixture)
	local domain: PublicTypes.DomainView = TestUtils.domain(fixture)
	local unavailable: number = 0
	table.insert(
		fixture.connections,
		view.OnUnavailable:Connect(function()
			unavailable += 1
		end)
	)
	TestUtils.commit(fixture, 12)
	for _, seconds: number in { 1, 2, 4, 8 } do
		local previous: number = #fixture.requests
		TestUtils.advance(fixture, seconds - 0.01)
		expect(#fixture.requests).toBe(previous)
		TestUtils.advance(fixture, 0.01)
		expect(#fixture.requests).toBe(previous + 1)
		expect(view:IsAvailable()).toBe(true)
	end
	expect(#fixture.requests).toBe(5)
	TestUtils.advance(fixture, 16)
	expect(view:IsAvailable()).toBe(false)
	expect(domain:GetState()).toBeNil()
	expect(TestUtils.view(fixture)).toBe(view)
	expect(unavailable).toBe(1)
	expect(fixture.faults[#fixture.faults].reason).toBe("ActorRecoveryExhausted")
	TestUtils.advance(fixture, 1000)
	TestUtils.baseline(fixture, 1, nil, 50, TestUtils.truth(), 2)
	expect(view:IsAvailable()).toBe(false)
	expect(#fixture.requests).toBe(5)
	expect(unavailable).toBe(1)
	TestUtils.commit(fixture, 11, { TestUtils.patch(60) }, {}, 2)
	expect(TestUtils.domain(fixture, nil, "ActorB"):GetState().current).toBe(60)
end)

it("does not extend the recovery deadline when replacement state remains incompatible", function()
	TestUtils.baseline(fixture)
	TestUtils.commit(fixture, 12)
	for _index: number = 1, 31 do
		fixture.runtime.consumer.OnBaselineReady(TestUtils.actor(fixture), 20, { Unknown = { value = 1 } })
		TestUtils.advance(fixture, 1)
	end
	expect(TestUtils.view(fixture):IsAvailable()).toBe(false)
	expect(#fixture.requests).toBe(5)
	expect(fixture.faults[#fixture.faults].reason).toBe("ActorRecoveryExhausted")
end)

it("expires against elapsed time when a scheduled callback runs late instead of extending the episode", function()
	TestUtils.baseline(fixture)
	TestUtils.commit(fixture, 12)
	local pending: TestUtils.Timer = fixture.clock.timers[1]
	assert(pending ~= nil, "Expected deferred retry")
	fixture.clock.now = 60
	pending.callback()
	expect(TestUtils.view(fixture):IsAvailable()).toBe(false)
	expect(#fixture.requests).toBe(1)
	expect(fixture.faults[#fixture.faults].reason).toBe("ActorRecoveryExhausted")
end)

it("bounds persistent send failure and invalid initial state without publishing an incomplete view", function()
	TestUtils.destroy(fixture)
	fixture = TestUtils.new(function(_payload: buffer)
		error("PersistentSendFailure", 0)
	end)
	TestUtils.send(
		fixture,
		{ { kind = "BaselineBegin", handle = 1, actorId = "ActorA", generation = 1, totalBytes = 1 } }
	)
	fixture.runtime.consumer.OnBaselineReady(TestUtils.actor(fixture), 10, { Unknown = { value = 1 } })
	TestUtils.advance(fixture, 31)
	expect(#fixture.requests).toBe(5)
	expect(fixture.runtime.registry.GetAllActorViews()).toEqual({})
	expect(fixture.faults[#fixture.faults].reason).toBe("ActorRecoveryExhausted")
	fixture.runtime.consumer.OnBaselineReady(TestUtils.actor(fixture), 20, TestUtils.truth())
	expect(fixture.runtime.registry.GetAllActorViews()).toEqual({})
	TestUtils.advance(fixture, 100)
	expect(#fixture.requests).toBe(5)
end)

for _, ending: string in { "replacement", "removal", "halt", "destroy" } do
	it("cancels recovery and fences retained timer callbacks after " .. ending, function()
		TestUtils.baseline(fixture)
		TestUtils.commit(fixture, 12)
		local stale: TestUtils.Timer = fixture.clock.timers[1]
		assert(stale ~= nil, "Recovery must schedule a bounded retry")
		if ending == "replacement" then
			TestUtils.baseline(fixture, 1, nil, 20, TestUtils.truth(50), 2)
		elseif ending == "removal" then
			TestUtils.send(fixture, { { kind = "ActorRemove", handle = 1 } })
		elseif ending == "halt" then
			TestUtils.send(fixture, { { kind = "ActorHalt", handle = 1 } })
		else
			fixture.runtime:Destroy()
		end
		expect(stale.cancelled).toBe(true)
		stale.callback()
		TestUtils.advance(fixture, 100)
		expect(#fixture.requests).toBe(1)
	end)
end

it("fences an earlier episode's callback while a new recovery episode is active", function()
	TestUtils.baseline(fixture)
	TestUtils.commit(fixture, 12)
	local stale: TestUtils.Timer = fixture.clock.timers[1]
	assert(stale ~= nil, "Expected retry timer")
	TestUtils.baseline(fixture, 1, nil, 20, TestUtils.truth(), 2)
	TestUtils.commit(fixture, 22)
	stale.callback()
	expect(#fixture.requests).toBe(2)
	TestUtils.advance(fixture, 1)
	expect(#fixture.requests).toBe(3)
end)

it("bounds connection-wide recovery traffic without retaining a request queue", function()
	for handle: number = 1, 40 do
		TestUtils.baseline(fixture, handle, "Actor" .. tostring(handle), 10, {})
		TestUtils.commit(fixture, 12, {}, {}, handle)
	end
	expect(#fixture.requests).toBe(32)
	TestUtils.advance(fixture, 7)
	expect(#fixture.requests).toBe(32)
	TestUtils.advance(fixture, 8)
	expect(#fixture.requests).toBe(64)
	TestUtils.advance(fixture, 100)
	expect(#fixture.requests).toBe(64)
	for _, view: PublicTypes.ActorView in fixture.runtime.registry.GetAllActorViews() do
		expect(view:IsAvailable()).toBe(false)
	end
end)

it("enforces per-Actor admission across rapidly succeeding recovery episodes", function()
	TestUtils.baseline(fixture)
	for generation: number = 2, 7 do
		TestUtils.commit(fixture, 12)
		TestUtils.baseline(fixture, 1, nil, 10, TestUtils.truth(), generation)
	end
	expect(#fixture.requests).toBe(4)
	TestUtils.advance(fixture, 100)
	expect(TestUtils.view(fixture):IsAvailable()).toBe(true)
	expect(#fixture.requests).toBe(4)
end)
