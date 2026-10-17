--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local PublicTypes = require(KRF.client.Actor.types)
local SignalTypes = require(KRF.shared.Signal.types)
local TestUtils = require(script.Parent.Utils.ActorViewTestUtils)

local fixture: TestUtils.Fixture
local suspended: { thread }
beforeEach(function()
	fixture = TestUtils.new()
	suspended = {}
end)
afterEach(function()
	for _, handler: thread in suspended do
		if coroutine.status(handler) ~= "dead" then
			task.cancel(handler)
		end
	end
	TestUtils.destroy(fixture)
end)

it("continues applying revisions while a consumer is yielded and preserves its historical event payload", function()
	TestUtils.baseline(fixture)
	local domain: PublicTypes.DomainView = TestUtils.domain(fixture)
	local event: SignalTypes.Event<any>? = domain:GetEvent("Changed")
	assert(event ~= nil, "Expected declared event")
	local entered: { number } = {}
	local resumed: { any } = {}
	table.insert(
		fixture.connections,
		event:Connect(function(payload: any)
			table.insert(entered, payload.amount)
			table.insert(suspended, coroutine.running())
			coroutine.yield()
			table.insert(
				resumed,
				{ amount = payload.amount, history = payload.history, current = domain:GetState().current }
			)
		end)
	)
	TestUtils.commit(
		fixture,
		11,
		{ TestUtils.patch(75) },
		{ { domainId = "Game.Stamina", eventId = "Changed", payload = { amount = 25, history = { 100, 75 } } } }
	)
	expect(entered).toEqual({ 25 })
	TestUtils.commit(fixture, 12, { TestUtils.patch(50) })
	expect(domain:GetState().current).toBe(50)
	expect(resumed).toEqual({})
	local completed: boolean, reason: any = coroutine.resume(suspended[1])
	-- The completed handler's coroutine now belongs to GoodSignal's runner pool.
	-- It must not be cancelled as if it were still a blocked consumer.
	table.remove(suspended, 1)
	expect(completed).toBe(true)
	expect(reason).toBeNil()
	expect(resumed).toEqual({ { amount = 25, history = { 100, 75 }, current = 50 } })
	expect(fixture.requests).toEqual({})
end)

it("permits a consumer to yield from OnChanged without delaying later semantic Fire or later commits", function()
	TestUtils.baseline(fixture)
	local domain: PublicTypes.DomainView = TestUtils.domain(fixture)
	local changes: { PublicTypes.DomainChange } = {}
	local events: { number } = {}
	table.insert(
		fixture.connections,
		domain.OnChanged:Connect(function(change: PublicTypes.DomainChange)
			table.insert(changes, change)
			table.insert(suspended, coroutine.running())
			coroutine.yield()
		end)
	)
	local event: SignalTypes.Event<any>? = TestUtils.domain(fixture, "Game.Counter"):GetEvent("Changed")
	assert(event ~= nil, "Expected counter event")
	table.insert(
		fixture.connections,
		event:Connect(function(payload: number)
			table.insert(events, payload)
		end)
	)
	TestUtils.commit(
		fixture,
		11,
		{ TestUtils.patch(75) },
		{ { domainId = "Game.Counter", eventId = "Changed", payload = 11 } }
	)
	TestUtils.commit(
		fixture,
		12,
		{ TestUtils.patch(50) },
		{ { domainId = "Game.Counter", eventId = "Changed", payload = 12 } }
	)
	expect(#changes).toBe(2)
	expect(changes[1].current.current).toBe(75)
	expect(changes[2].previous.current).toBe(75)
	expect(events).toEqual({ 11, 12 })
	expect(domain:GetState().current).toBe(50)
end)

it("does not roll back or desync when a public consumer throws", function()
	TestUtils.baseline(fixture)
	local domain: PublicTypes.DomainView = TestUtils.domain(fixture)
	local calls: number = 0
	table.insert(
		fixture.connections,
		domain.OnChanged:Connect(function(_change: PublicTypes.DomainChange)
			calls += 1
			error("N5ExpectedConsumerFailure", 0)
		end)
	)
	TestUtils.commit(fixture, 11, { TestUtils.patch(75) })
	TestUtils.commit(fixture, 12, { TestUtils.patch(50) })
	expect(calls).toBe(2)
	expect(domain:GetState().current).toBe(50)
	expect(fixture.requests).toEqual({})
	expect(fixture.faults).toEqual({})
end)
