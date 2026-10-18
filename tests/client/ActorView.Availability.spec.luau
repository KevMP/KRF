--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local PublicTypes = require(KRF.client.Actor.types)
local SharedTypes = require(KRF.shared.Networking.types)
local TestUtils = require(script.Parent.Utils.ActorViewTestUtils)

local fixture: TestUtils.Fixture

beforeEach(function()
	fixture = TestUtils.new()
end)

afterEach(function()
	TestUtils.destroy(fixture)
end)

it("observes membership-only replacements with immutable sorted deltas and fresh reappearing domains", function()
	TestUtils.baseline(fixture)
	local view: PublicTypes.ActorView = TestUtils.view(fixture)
	local owner: PublicTypes.DomainView = TestUtils.domain(fixture, "Game.Owner")
	local stamina: PublicTypes.DomainView = TestUtils.domain(fixture)
	local changes: { PublicTypes.DomainMembershipChange } = {}
	local observations: { any } = {}

	table.insert(
		fixture.connections,
		view.OnDomainsChanged:Connect(function(change: PublicTypes.DomainMembershipChange)
			table.insert(changes, change)

			table.insert(
				observations,
				{ ids = view:GetDomainIds(), retired = owner:GetState(), available = view:IsAvailable() }
			)
		end)
	)

	local truth: { [string]: SharedTypes.ActorDomainTruth } = TestUtils.truth()
	truth["Game.Owner"] = nil
	truth["Game.Counter"] = nil
	TestUtils.baseline(fixture, 1, nil, 20, truth, 2)
	expect(changes).toEqual({ { added = {}, removed = { "Game.Counter", "Game.Owner" } } })
	expect(observations).toEqual({ { ids = { "Game.Stamina" }, available = true } })
	expect(TestUtils.domain(fixture)).toBe(stamina)
	expect(table.isfrozen(changes[1])).toBe(true)
	expect(table.isfrozen(changes[1].added)).toBe(true)
	expect(table.isfrozen(changes[1].removed)).toBe(true)
	TestUtils.baseline(fixture, 1, nil, 21, TestUtils.truth(), 3)
	expect(changes[2]).toEqual({ added = { "Game.Counter", "Game.Owner" }, removed = {} })
	expect(TestUtils.domain(fixture, "Game.Owner")).never.toBe(owner)
	expect(owner:GetState()).toBeNil()
end)

it(
	"installs all replacement truth and retires removed domains before membership then retained state notifications",
	function()
		TestUtils.baseline(fixture)
		local view: PublicTypes.ActorView = TestUtils.view(fixture)
		local owner: PublicTypes.DomainView = TestUtils.domain(fixture, "Game.Owner")
		local order: { string } = {}
		local observed: any = nil

		table.insert(
			fixture.connections,
			view.OnDomainsChanged:Connect(function(_change: PublicTypes.DomainMembershipChange)
				table.insert(order, "Domains")

				observed = {
					current = TestUtils.domain(fixture):GetState().current,
					retired = owner:GetState(),
					domain = view:GetDomain("Game.Owner"),
				}
			end)
		)

		table.insert(
			fixture.connections,
			TestUtils.domain(fixture).OnChanged:Connect(function(_change: PublicTypes.DomainChange)
				table.insert(order, "State")
			end)
		)

		local truth: { [string]: SharedTypes.ActorDomainTruth } = TestUtils.truth(50)
		truth["Game.Owner"] = nil
		TestUtils.baseline(fixture, 1, nil, 20, truth, 2)
		expect(order).toEqual({ "Domains", "State" })
		expect(observed).toEqual({ current = 50 })
	end
)

it("does not synthesize initial or unchanged membership changes, including a live empty domain set", function()
	local changes: number = 0

	table.insert(
		fixture.connections,
		fixture.runtime.registry.OnActorViewAdded:Connect(function(view: PublicTypes.ActorView)
			table.insert(
				fixture.connections,
				view.OnDomainsChanged:Connect(function(_change: PublicTypes.DomainMembershipChange)
					changes += 1
				end)
			)
		end)
	)

	TestUtils.baseline(fixture, 1, nil, 10, {})
	local view: PublicTypes.ActorView = TestUtils.view(fixture)
	expect(view:IsAvailable()).toBe(true)
	TestUtils.baseline(fixture, 1, nil, 11, {}, 2)
	TestUtils.commit(fixture, 12)
	expect(changes).toBe(0)
	expect(view:GetDomainIds()).toEqual({})
end)

it("keeps valid Optional nil distinguishable from retirement and emits nothing for rejected replacement", function()
	local truth: { [string]: SharedTypes.ActorDomainTruth } = TestUtils.truth()
	truth["Game.Owner"] = {}
	TestUtils.baseline(fixture, 1, nil, 10, truth)
	local view: PublicTypes.ActorView = TestUtils.view(fixture)
	local owner: PublicTypes.DomainView = TestUtils.domain(fixture, "Game.Owner")
	local changes: number = 0

	table.insert(
		fixture.connections,
		view.OnDomainsChanged:Connect(function(_change: PublicTypes.DomainMembershipChange)
			changes += 1
		end)
	)

	expect(owner:GetState()).toBeNil()
	expect(view:IsAvailable()).toBe(true)
	expect(view:GetDomain("Game.Owner")).toBe(owner)
	fixture.runtime.consumer.OnBaselineReady(TestUtils.actor(fixture), 20, { Unknown = { value = 1 } })
	expect(changes).toBe(0)
	expect(view:GetDomain("Game.Owner")).toBe(owner)
	expect(view:IsAvailable()).toBe(true)
end)

for _, empty: boolean in { false, true } do
	it("publishes terminal unavailability once after invalidation with empty domains=" .. tostring(empty), function()
		TestUtils.baseline(fixture, 1, nil, 10, if empty then {} else TestUtils.truth())
		local view: PublicTypes.ActorView = TestUtils.view(fixture)
		local order: { string } = {}
		local observedMembership: { any } = {}
		local observedUnavailable: any = nil

		table.insert(
			fixture.connections,
			view.OnDomainsChanged:Connect(function(change: PublicTypes.DomainMembershipChange)
				table.insert(order, "Domains")

				table.insert(
					observedMembership,
					{ change = change, available = view:IsAvailable(), ids = view:GetDomainIds() }
				)
			end)
		)

		table.insert(
			fixture.connections,
			view.OnUnavailable:Connect(function()
				table.insert(order, "Unavailable")

				observedUnavailable = {
					available = view:IsAvailable(),
					ids = view:GetDomainIds(),
					registered = fixture.runtime.registry.GetActorViewById("ActorA"),
				}
			end)
		)

		TestUtils.commit(fixture, 12)
		expect(view:IsAvailable()).toBe(true)
		TestUtils.send(fixture, { { kind = "ActorHalt", handle = 1 }, { kind = "ActorHalt", handle = 1 } })
		expect(order).toEqual(if empty then { "Unavailable" } else { "Domains", "Unavailable" })

		local expectedMembership: { any } = if empty
			then {}
			else {
				{
					change = { added = {}, removed = { "Game.Counter", "Game.Owner", "Game.Stamina" } },
					available = false,
					ids = {},
				},
			}

		expect(observedMembership).toEqual(expectedMembership)
		expect(observedUnavailable).toEqual({ available = false, ids = {}, registered = view })
	end)
end

it("retires new Actor-level signals on removal without synthesizing terminal-failure notifications", function()
	TestUtils.baseline(fixture)
	local view: PublicTypes.ActorView = TestUtils.view(fixture)
	local notifications: number = 0

	table.insert(
		fixture.connections,
		view.OnUnavailable:Connect(function()
			notifications += 1
		end)
	)

	table.insert(
		fixture.connections,
		view.OnDomainsChanged:Connect(function(_change: PublicTypes.DomainMembershipChange)
			notifications += 1
		end)
	)

	TestUtils.send(fixture, { { kind = "ActorRemove", handle = 1 } })
	expect(view:IsAvailable()).toBe(false)
	expect(notifications).toBe(0)

	local connected: boolean = pcall(function()
		view.OnUnavailable:Connect(function() end)
	end)

	expect(connected).toBe(false)

	connected = pcall(function()
		view.OnDomainsChanged:Connect(function(_change: PublicTypes.DomainMembershipChange) end)
	end)

	expect(connected).toBe(false)
end)

it("allows removal from a membership callback and suppresses later retired-domain notification", function()
	TestUtils.baseline(fixture)
	local view: PublicTypes.ActorView = TestUtils.view(fixture)
	local changes: number = 0

	table.insert(
		fixture.connections,
		TestUtils.domain(fixture).OnChanged:Connect(function(_change: PublicTypes.DomainChange)
			changes += 1
		end)
	)

	table.insert(
		fixture.connections,
		view.OnDomainsChanged:Connect(function(_change: PublicTypes.DomainMembershipChange)
			fixture.runtime.consumer.OnActorRemoved(TestUtils.actor(fixture))
		end)
	)

	local truth: { [string]: SharedTypes.ActorDomainTruth } = TestUtils.truth(50)
	truth["Game.Owner"] = nil
	TestUtils.baseline(fixture, 1, nil, 20, truth, 2)
	expect(fixture.runtime.registry.GetAllActorViews()).toEqual({})
	expect(view:IsAvailable()).toBe(false)
	expect(changes).toBe(0)
end)
