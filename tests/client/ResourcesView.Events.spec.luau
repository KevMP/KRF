--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local Types = require(KRF.client.Actor.types)
local GoodSignal: any = require(KRF.shared.Signal.GoodSignal)
local TestUtils = require(script.Parent.Utils.ResourcesViewTestUtils)

local fixture: TestUtils.Fixture
local originalFire: any = GoodSignal.Fire
local suspended: { thread } = {}

beforeEach(function()
	fixture = TestUtils.new()
end)

afterEach(function()
	GoodSignal.Fire = originalFire

	for _, handler: thread in suspended do
		pcall(task.cancel, handler)
	end

	suspended = {}
	TestUtils.destroy(fixture)
end)

it("does not synthesize Resource change Fire calls while constructing an initial-baseline facade", function()
	TestUtils.destroy(fixture)
	local fires: { Types.ResourceViewChange } = {}

	GoodSignal.Fire = function(self: any, ...: any)
		local first: any = ...

		if type(first) == "table" and first.resourceId ~= nil then
			table.insert(fires, first)
		end

		originalFire(self, ...)
	end

	fixture = TestUtils.new()
	expect(fires).toEqual({})
end)

it("derives previous and current change snapshots from one synchronized-time sample", function()
	local changes: { Types.ResourceViewChange } = {}

	fixture.view.OnResourceChanged:Connect(function(change: Types.ResourceViewChange)
		table.insert(changes, change)
	end)

	fixture.clock.now = 1002
	fixture.clock.reads = 0
	fixture.clock.increment = 1

	TestUtils.install(
		fixture,
		{ ["Resource.Mana"] = { anchorValue = 20, anchorTime = 1002, min = 0, max = 100, regenRate = 5 } },
		"Commit"
	)

	expect(changes).toEqual({
		{
			resourceId = "Resource.Mana",
			previous = { resourceId = "Resource.Mana", current = 60, min = 0, max = 100, regenRate = 10 },
			current = { resourceId = "Resource.Mana", current = 20, min = 0, max = 100, regenRate = 5 },
			source = "Commit",
		},
	})

	expect(fixture.clock.reads).toBe(1)
	expect(table.isfrozen(changes[1])).toBe(true)
	local previous: Types.ResourceSnapshot? = changes[1].previous
	local current: Types.ResourceSnapshot? = changes[1].current
	assert(previous ~= nil and current ~= nil, "An anchor replacement must include both point-in-time snapshots")
	expect(table.isfrozen(previous)).toBe(true)
	expect(table.isfrozen(current)).toBe(true)
end)

for _, source: Types.DomainChangeSource in { "Commit", "Baseline" } do
	it(
		"derives assignment and removal payloads from " .. source .. " Map membership without semantic events",
		function()
			local changes: { Types.ResourceViewChange } = {}

			fixture.view.OnResourceChanged:Connect(function(change: Types.ResourceViewChange)
				table.insert(changes, change)
			end)

			TestUtils.install(
				fixture,
				{ ["Resource.Rage"] = { anchorValue = 10, anchorTime = 1000, min = 0, max = 50 } },
				source
			)

			expect(changes).toEqual({
				{
					resourceId = "Resource.Mana",
					previous = { resourceId = "Resource.Mana", current = 40, min = 0, max = 100, regenRate = 10 },
					source = source,
				},
				{
					resourceId = "Resource.Rage",
					current = { resourceId = "Resource.Rage", current = 10, min = 0, max = 50 },
					source = source,
				},
			})
		end
	)
end

for _, field: string in { "anchorValue", "anchorTime", "min", "max", "regenRate" } do
	it("emits a typed Commit change when only replicated " .. field .. " differs", function()
		local changes: { Types.ResourceViewChange } = {}

		fixture.view.OnResourceChanged:Connect(function(change: Types.ResourceViewChange)
			table.insert(changes, change)
		end)

		TestUtils.install(fixture, {
			["Resource.Mana"] = {
				anchorValue = if field == "anchorValue" then 30 else 40,
				anchorTime = if field == "anchorTime" then 999 else 1000,
				min = if field == "min" then 10 else 0,
				max = if field == "max" then 90 else 100,
				regenRate = if field == "regenRate" then 15 else 10,
			},
		}, "Commit")

		expect(#changes).toBe(1)
		expect(changes[1].resourceId).toBe("Resource.Mana")
		expect(changes[1].source).toBe("Commit")

		expect(changes[1].previous).toEqual({
			resourceId = "Resource.Mana",
			current = 40,
			min = 0,
			max = 100,
			regenRate = 10,
		})

		expect(changes[1].current).toEqual({
			resourceId = "Resource.Mana",
			current = if field == "anchorValue" then 30 elseif field == "anchorTime" then 50 else 40,
			min = if field == "min" then 10 else 0,
			max = if field == "max" then 90 else 100,
			regenRate = if field == "regenRate" then 15 else 10,
		})
	end)
end

it("treats removed optional regen metadata as a real state change", function()
	local changes: { Types.ResourceViewChange } = {}

	fixture.view.OnResourceChanged:Connect(function(change: Types.ResourceViewChange)
		table.insert(changes, change)
	end)

	TestUtils.install(
		fixture,
		{ ["Resource.Mana"] = { anchorValue = 40, anchorTime = 1000, min = 0, max = 100 } },
		"Commit"
	)

	expect(#changes).toBe(1)
	expect(changes[1].current).toEqual({ resourceId = "Resource.Mana", current = 40, min = 0, max = 100 })
end)

it("emits no change from local time alone, including reaching displayed max", function()
	local changes: number = 0

	fixture.view.OnResourceChanged:Connect(function()
		changes += 1
	end)

	for index: number = 1, 100 do
		fixture.clock.now = 1000 + index * 0.1
		fixture.view:GetCurrent("Resource.Mana")
		fixture.view:GetAssignedResources()
	end

	expect(changes).toBe(0)
	expect(fixture.view:GetCurrent("Resource.Mana")).toBe(100)
end)

it("compares replacement entries by value and ignores unchanged entries even after time advances", function()
	local changes: { Types.ResourceViewChange } = {}

	fixture.view.OnResourceChanged:Connect(function(change: Types.ResourceViewChange)
		table.insert(changes, change)
	end)

	fixture.clock.now = 1002

	TestUtils.install(
		fixture,
		{ ["Resource.Mana"] = { anchorValue = 40, anchorTime = 1000, min = 0, max = 100, regenRate = 10 } },
		"Baseline"
	)

	expect(changes).toEqual({})

	TestUtils.install(fixture, {
		["Resource.Mana"] = { anchorValue = 40, anchorTime = 1000, min = 0, max = 100, regenRate = 10 },
		["Resource.Rage"] = { anchorValue = 10, anchorTime = 1002, min = 0, max = 50 },
	}, "Baseline")

	expect(changes).toEqual({
		{
			resourceId = "Resource.Rage",
			current = { resourceId = "Resource.Rage", current = 10, min = 0, max = 50 },
			source = "Baseline",
		},
	})
end)

it("keeps installed truth and healthy subscriptions intact when another consumer yields or throws", function()
	local changes: { Types.ResourceViewChange } = {}

	fixture.view.OnResourceChanged:Connect(function()
		table.insert(suspended, coroutine.running())
		coroutine.yield()
	end)

	fixture.view.OnResourceChanged:Connect(function()
		error("ResourceViewConsumerFailure")
	end)

	fixture.view.OnResourceChanged:Connect(function(change: Types.ResourceViewChange)
		table.insert(changes, change)
	end)

	local completed: boolean = pcall(function()
		TestUtils.install(
			fixture,
			{ ["Resource.Mana"] = { anchorValue = 30, anchorTime = 1000, min = 0, max = 100 } },
			"Commit"
		)

		TestUtils.install(
			fixture,
			{ ["Resource.Mana"] = { anchorValue = 20, anchorTime = 1000, min = 0, max = 100 } },
			"Commit"
		)
	end)

	expect(completed).toBe(true)
	expect(#changes).toBe(2)
	expect(fixture.view:GetCurrent("Resource.Mana")).toBe(20)
	expect(fixture.domain.view:GetState()["Resource.Mana"].anchorValue).toBe(20)
end)
