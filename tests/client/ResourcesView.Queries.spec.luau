--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local Types = require(KRF.client.Actor.types)
local Resources: Types.ResourcesViewModule = require(KRF.client.Actor.ResourcesView)
local TestUtils = require(script.Parent.Utils.ResourcesViewTestUtils)

local fixture: TestUtils.Fixture

beforeEach(function()
	fixture = TestUtils.new()
end)

afterEach(function()
	TestUtils.destroy(fixture)
end)

it("reads assigned Resource snapshots and metadata from N5 truth without exposing anchor fields", function()
	expect(fixture.view:HasResource("Resource.Mana")).toBe(true)

	expect(fixture.view:GetResource("Resource.Mana")).toEqual({
		resourceId = "Resource.Mana",
		current = 40,
		min = 0,
		max = 100,
		regenRate = 10,
	})

	expect(fixture.view:GetCurrent("Resource.Mana")).toBe(40)
	expect(fixture.view:GetMin("Resource.Mana")).toBe(0)
	expect(fixture.view:GetMax("Resource.Mana")).toBe(100)
	expect(fixture.view:GetRegenRate("Resource.Mana")).toBe(10)
	local snapshot: Types.ResourceSnapshot? = fixture.view:GetResource("Resource.Mana")
	assert(snapshot ~= nil, "Assigned Resource must return a typed snapshot")
	expect((snapshot :: any).anchorValue).toBeNil()
	expect((snapshot :: any).anchorTime).toBeNil()
end)

for _, id: string in { "Resource.Unassigned", "Private.Secret", "Unknown" } do
	it("returns no assignment or metadata for " .. id, function()
		expect(fixture.view:HasResource(id)).toBe(false)
		expect(fixture.view:GetResource(id)).toBeNil()
		expect(fixture.view:GetCurrent(id)).toBeNil()
		expect(fixture.view:GetMin(id)).toBeNil()
		expect(fixture.view:GetMax(id)).toBeNil()
		expect(fixture.view:GetRegenRate(id)).toBeNil()
	end)
end

for _, case: { name: string, rate: number?, current: number } in
	{
		{ name = "positive", rate = 10, current = 60 },
		{ name = "zero", rate = 0, current = 40 },
		{ name = "negative", rate = -5, current = 40 },
		{ name = "absent", current = 40 },
	}
do
	it("derives a " .. case.name .. " rate using only the supported positive regeneration semantics", function()
		TestUtils.install(
			fixture,
			{ ["Resource.Mana"] = { anchorValue = 40, anchorTime = 1000, min = 0, max = 100, regenRate = case.rate } },
			"Commit"
		)

		fixture.clock.now = 1002
		expect(fixture.view:GetCurrent("Resource.Mana")).toBe(case.current)
		expect(fixture.view:GetRegenRate("Resource.Mana")).toBe(case.rate)
	end)
end

for _, case: { name: string, now: number, current: number } in
	{
		{ name = "upper bound", now = 1020, current = 100 },
		{ name = "future anchor", now = 999, current = 30 },
		{ name = "lower bound", now = 980, current = 0 },
	}
do
	it("clamps synchronized-time derivation at the " .. case.name, function()
		fixture.clock.now = case.now
		expect(fixture.view:GetCurrent("Resource.Mana")).toBe(case.current)
		expect(fixture.view:HasResource("Resource.Mana")).toBe(true)
	end)
end

it("samples synchronized time exactly once for one coherent Resource snapshot", function()
	fixture.clock.now = 1001
	fixture.clock.reads = 0
	fixture.clock.increment = 1

	expect(fixture.view:GetResource("Resource.Mana")).toEqual({
		resourceId = "Resource.Mana",
		current = 50,
		min = 0,
		max = 100,
		regenRate = 10,
	})

	expect(fixture.clock.reads).toBe(1)
end)

it("returns each assignment once in resourceId order using one shared time sample", function()
	TestUtils.install(fixture, {
		["Resource.Z"] = { anchorValue = 40, anchorTime = 1000, min = 0, max = 100, regenRate = 10 },
		["Resource.A"] = { anchorValue = 40, anchorTime = 1000, min = 0, max = 100, regenRate = 10 },
	}, "Commit")

	fixture.clock.now = 1001
	fixture.clock.reads = 0
	fixture.clock.increment = 1

	local assigned: { Types.ResourceSnapshot } = fixture.view:GetAssignedResources()

	expect(assigned).toEqual({
		{ resourceId = "Resource.A", current = 50, min = 0, max = 100, regenRate = 10 },
		{ resourceId = "Resource.Z", current = 50, min = 0, max = 100, regenRate = 10 },
	})

	expect(fixture.clock.reads).toBe(1)
	expect(table.isfrozen(assigned)).toBe(true)
	expect(table.isfrozen(assigned[1])).toBe(true)
	expect(table.isfrozen(assigned[2])).toBe(true)
end)

it("freezes point-in-time snapshots and keeps retained snapshots unchanged as time and N5 truth advance", function()
	local snapshot: Types.ResourceSnapshot? = fixture.view:GetResource("Resource.Mana")
	assert(snapshot ~= nil, "Expected point-in-time snapshot")
	expect(table.isfrozen(snapshot)).toBe(true)

	local mutated: boolean = pcall(function()
		(snapshot :: any).current = 999
	end)

	expect(mutated).toBe(false)
	fixture.clock.now = 1003
	expect(snapshot.current).toBe(40)
	expect(fixture.view:GetCurrent("Resource.Mana")).toBe(70)

	TestUtils.install(
		fixture,
		{ ["Resource.Mana"] = { anchorValue = 20, anchorTime = 1003, min = 0, max = 80, regenRate = 5 } },
		"Commit"
	)

	expect(snapshot.current).toBe(40)
	expect(snapshot.max).toBe(100)
	expect(fixture.view:GetCurrent("Resource.Mana")).toBe(20)
	expect(fixture.domain.view:GetState()["Resource.Mana"].anchorValue).toBe(20)
end)

it("keeps the public facade frozen and exposes neither mutation methods nor the owning change Signal", function()
	expect(table.isfrozen(fixture.view)).toBe(true)

	for _, name: string in { "SetCurrent", "Spend", "Restore", "Drain", "AddResource", "Destroy", "InstallState" } do
		expect((fixture.view :: any)[name]).toBeNil()
	end

	local writable: boolean = pcall(function()
		(fixture.view :: any).GetCurrent = function()
			return 999
		end
	end)

	expect(writable).toBe(false)

	local exposedSignal: boolean = pcall(function()
		return (fixture.view.OnResourceChanged :: any).Fire
	end)

	expect(exposedSignal).toBe(false)
end)

it("returns an empty immutable view when the protocol has no Resources domain", function()
	fixture.owner:Destroy()

	fixture.owner = Resources.new(function(): Types.DomainView?
		return nil
	end)

	fixture.view = fixture.owner.view
	expect(fixture.view:GetAssignedResources()).toEqual({})
	expect(table.isfrozen(fixture.view:GetAssignedResources())).toBe(true)
	expect(fixture.view:HasResource("Resource.Mana")).toBe(false)
	expect(fixture.view:GetResource("Resource.Mana")).toBeNil()
	expect(fixture.view:GetCurrent("Resource.Mana")).toBeNil()
end)

it("tears down subscriptions idempotently and makes stale queries empty", function()
	local changes: number = 0

	fixture.view.OnResourceChanged:Connect(function()
		changes += 1
	end)

	fixture.owner:Destroy()
	fixture.owner:Destroy()

	TestUtils.install(
		fixture,
		{ ["Resource.Mana"] = { anchorValue = 20, anchorTime = 1000, min = 0, max = 100 } },
		"Commit"
	)

	expect(changes).toBe(0)
	expect(fixture.view:GetAssignedResources()).toEqual({})
	expect(fixture.view:GetResource("Resource.Mana")).toBeNil()

	local connected: boolean = pcall(function()
		fixture.view.OnResourceChanged:Connect(function() end)
	end)

	expect(connected).toBe(false)
end)
