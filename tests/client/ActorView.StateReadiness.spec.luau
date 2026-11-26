--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local PublicTypes = require(KRF.client.Actor.types)
local ClientNetworkingTypes = require(KRF.client.Networking.types)
local TestUtils = require(script.Parent.Utils.ActorViewTestUtils)

type Transition = { actor: PublicTypes.ActorView, readiness: ClientNetworkingTypes.ActorViewStateReadiness }

local fixture: TestUtils.Fixture
local transitions: { Transition }
local order: { string }

beforeEach(function()
	fixture = TestUtils.new()
	transitions = {}
	order = {}

	fixture.runtime:ObserveStateReadiness(
		function(actor: PublicTypes.ActorView, readiness: ClientNetworkingTypes.ActorViewStateReadiness)
			table.insert(transitions, { actor = actor, readiness = readiness })
			table.insert(order, readiness)
		end
	)
end)

afterEach(function()
	TestUtils.destroy(fixture)
end)

it("reports Ready once after the first baseline is installed and before the registry Added signal", function()
	local readyWhenAdded: boolean? = nil

	table.insert(
		fixture.connections,
		fixture.runtime.registry.OnActorViewAdded:Connect(function(view: PublicTypes.ActorView)
			readyWhenAdded = fixture.runtime:IsStateReady(view)
			table.insert(order, "Added")
		end)
	)

	TestUtils.baseline(fixture)
	local view: PublicTypes.ActorView = TestUtils.view(fixture)
	expect(order).toEqual({ "Ready", "Added" })
	expect(readyWhenAdded).toBe(true)
	expect(transitions[1].actor).toBe(view)
	expect(fixture.runtime:IsStateReady(view)).toBe(true)
	TestUtils.commit(fixture, 11, { TestUtils.patch(75) })
	expect(order).toEqual({ "Ready", "Added" })
end)

it("reports Stale once before recovery starts while the previous view remains available", function()
	TestUtils.baseline(fixture)
	local view: PublicTypes.ActorView = TestUtils.view(fixture)
	local requestsAtStale: number? = nil

	fixture.runtime:ObserveStateReadiness(
		function(_actor: PublicTypes.ActorView, readiness: ClientNetworkingTypes.ActorViewStateReadiness)
			if readiness == "Stale" then
				requestsAtStale = #fixture.requests
			end
		end
	)

	TestUtils.commit(fixture, 13, { TestUtils.patch(5) })
	expect(requestsAtStale).toBe(0)
	expect(#fixture.requests).toBe(1)
	TestUtils.commit(fixture, 14, { TestUtils.patch(5) })
	fixture.runtime.consumer.OnActorFault(TestUtils.actor(fixture), "DecodeFailed")
	expect(order).toEqual({ "Ready", "Stale" })
	expect(transitions[2].actor).toBe(view)
	expect(view:IsAvailable()).toBe(true)
	expect(TestUtils.domain(fixture):GetState().current).toBe(100)
	expect(fixture.runtime:IsStateReady(view)).toBe(false)
end)

it("reports Ready after a replacement baseline installs its truth and before public change notifications", function()
	TestUtils.baseline(fixture)
	local view: PublicTypes.ActorView = TestUtils.view(fixture)
	local domain: PublicTypes.DomainView = TestUtils.domain(fixture)
	TestUtils.commit(fixture, 13, { TestUtils.patch(5) })
	local stateAtReady: number? = nil
	local readyAtNotification: boolean? = nil

	fixture.runtime:ObserveStateReadiness(
		function(actor: PublicTypes.ActorView, readiness: ClientNetworkingTypes.ActorViewStateReadiness)
			if readiness == "Ready" then
				stateAtReady = domain:GetState().current
				readyAtNotification = fixture.runtime:IsStateReady(actor)
			end
		end
	)

	table.insert(
		fixture.connections,
		domain.OnChanged:Connect(function(_change: PublicTypes.DomainChange)
			table.insert(order, "Changed")
		end)
	)

	TestUtils.baseline(fixture, 1, "ActorA", 20, TestUtils.truth(50), 2)
	expect(TestUtils.view(fixture)).toBe(view)
	expect(order).toEqual({ "Ready", "Stale", "Ready", "Changed" })
	expect(stateAtReady).toBe(50)
	expect(readyAtNotification).toBe(true)
	expect(fixture.runtime:IsStateReady(view)).toBe(true)
end)

it("never reports Ready after a terminal halt and forgets removed or foreign views", function()
	TestUtils.baseline(fixture)
	local view: PublicTypes.ActorView = TestUtils.view(fixture)
	local actor: ClientNetworkingTypes.ActorStreamRecord = TestUtils.actor(fixture)
	fixture.runtime.consumer.OnActorHalted(actor)
	expect(fixture.runtime:IsStateReady(view)).toBe(false)
	TestUtils.baseline(fixture, 1, "ActorA", 20, TestUtils.truth(50), 2)
	expect(order).toEqual({ "Ready" })
	fixture.runtime.consumer.OnActorRemoved(actor)
	expect(fixture.runtime:IsStateReady(view)).toBe(false)
	expect(fixture.runtime:IsStateReady(table.freeze({}) :: any)).toBe(false)
end)

it("reports exhausted recovery as unavailable without a Ready transition", function()
	TestUtils.baseline(fixture)
	local view: PublicTypes.ActorView = TestUtils.view(fixture)
	TestUtils.commit(fixture, 13, { TestUtils.patch(5) })
	TestUtils.advance(fixture, 40)
	expect(view:IsAvailable()).toBe(false)
	expect(fixture.runtime:IsStateReady(view)).toBe(false)
	expect(order).toEqual({ "Ready", "Stale" })
end)

it("contains observer faults and stops notifying after disconnect or Destroy", function()
	local faulty: number = 0

	local stop: () -> () = fixture.runtime:ObserveStateReadiness(function()
		faulty += 1
		error("Expected observer failure")
	end)

	local skipped: number = 0
	local stopSkipped: (() -> ())? = nil

	fixture.runtime:ObserveStateReadiness(function()
		local stopOther: (() -> ())? = stopSkipped

		if stopOther ~= nil then
			stopOther()
		end
	end)

	stopSkipped = fixture.runtime:ObserveStateReadiness(function()
		skipped += 1
	end)

	TestUtils.baseline(fixture)
	expect(faulty).toBe(1)
	expect(skipped).toBe(0)
	expect(order).toEqual({ "Ready" })
	stop()
	stop()
	TestUtils.commit(fixture, 13, { TestUtils.patch(5) })
	expect(faulty).toBe(1)
	expect(order).toEqual({ "Ready", "Stale" })
	local view: PublicTypes.ActorView = TestUtils.view(fixture)
	fixture.runtime:Destroy()
	expect(fixture.runtime:IsStateReady(view)).toBe(false)

	local inert: () -> () = fixture.runtime:ObserveStateReadiness(function()
		faulty += 1
	end)

	inert()
	expect(faulty).toBe(1)
end)
