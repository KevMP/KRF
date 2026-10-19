--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local ResourceTypes = require(KRF.server.Resource.types)
local TestUtils = require(script.Parent.Parent.Utils.Networking.ResourcesReplicationTestUtils)

local fixture: TestUtils.Fixture

beforeEach(function()
	fixture = TestUtils.new()
end)

afterEach(function()
	TestUtils.destroy(fixture)
end)

it("returns complete resolved authority without adding a public regen query or leaking mutable records", function()
	local state: ResourceTypes.ResourceReplicationState? = fixture.resources:_getReplicationState("Resource.Mana")
	expect(state).toEqual({ current = 40, min = 0, max = 100, regenRate = 10 })
	assert(state ~= nil, "Assigned Resource must have complete replication state")
	expect(table.isfrozen(state)).toBe(true)
	expect((fixture.resources :: any).GetRegenRate).toBeNil()
	expect((state :: any).definition).toBeNil()
	expect(fixture.resources:Spend("Resource.Mana", 5)).toBe(true)
	expect(state.current).toBe(40)

	expect(fixture.resources:_getReplicationState("Resource.Mana")).toEqual({
		current = 35,
		min = 0,
		max = 100,
		regenRate = 10,
	})
end)

it("distinguishes no regen from zero and negative resolved regen without inventing decay", function()
	expect(fixture.resources:AddResource("Resource.Rage", 12)).toBe(true)
	expect(fixture.resources:_getReplicationState("Resource.Rage")).toEqual({ current = 12, min = 0, max = 50 })

	for _, rate: number in { 0, -5 } do
		expect(fixture.properties:SetBaseProperty("ManaRegen", rate)).toBe(true)

		expect(fixture.resources:_getReplicationState("Resource.Mana")).toEqual({
			current = 40,
			min = 0,
			max = 100,
			regenRate = rate,
		})

		fixture.resources:Step(1)
		expect(fixture.resources:GetCurrent("Resource.Mana")).toBe(40)
	end
end)

it("returns nil for unassigned, unknown and destroyed Resource state", function()
	expect(fixture.resources:_getReplicationState("Resource.Unassigned")).toBeNil()
	expect(fixture.resources:_getReplicationState("Unknown")).toBeNil()
	fixture.resources:Destroy()
	expect(fixture.resources:_getReplicationState("Resource.Mana")).toBeNil()
end)

for _, operation: string in { "SetCurrent", "Spend", "Restore", "Drain" } do
	it("commits " .. operation .. " after authority changes and before its public callback", function()
		local order: { string } = {}
		local mutations: { ResourceTypes.ResourceMutation } = {}
		local captured: number? = nil

		local disconnect = fixture.resources:_observeMutations({
			Commit = function(touched: { ResourceTypes.ResourceMutation })
				mutations = touched
				captured = fixture.resources:GetCurrent("Resource.Mana")
				table.insert(order, "Commit")
			end,
			Dispatch = function()
				table.insert(order, "Dispatch")
			end,
		})

		table.insert(fixture.disconnects, disconnect)

		fixture.resources.OnResourceChanged:Connect(function()
			expect(order[1]).toBe("Commit")
			table.insert(order, "Public")
		end)

		local mutate: (ResourceTypes.ResourceController, string, number) -> (boolean, string?) = (
			fixture.resources :: any
		)[operation]

		local success: boolean, reason: string? = mutate(fixture.resources, "Resource.Mana", 10)
		expect(reason).toBeNil()
		expect(success).toBe(true)
		expect(mutations).toEqual({ { resourceId = "Resource.Mana", kind = "Discrete" } })
		expect(captured).toBe(if operation == "SetCurrent" then 10 elseif operation == "Restore" then 50 else 30)
		expect(order[1]).toBe("Commit")
		expect(table.find(order, "Public") ~= nil).toBe(true)
		expect(table.find(order, "Dispatch") ~= nil).toBe(true)
	end)
end

it("commits Added before OnResourceAdded and captures the clamped override", function()
	local mutations: { ResourceTypes.ResourceMutation } = {}
	local captured: number? = nil
	local publicSawCommit: boolean = false

	fixture.resources:_observeMutations({
		Commit = function(touched: { ResourceTypes.ResourceMutation })
			mutations = touched
			captured = fixture.resources:GetCurrent("Resource.Rage")
		end,
		Dispatch = function() end,
	})

	fixture.resources.OnResourceAdded:Connect(function()
		publicSawCommit = #mutations == 1
	end)

	expect(fixture.resources:AddResource("Resource.Rage", 80)).toBe(true)
	expect(mutations).toEqual({ { resourceId = "Resource.Rage", kind = "Added" } })
	expect(captured).toBe(50)
	expect(publicSawCommit).toBe(true)
end)

it("reports regen-only Property recomputation privately while preserving public event silence", function()
	local mutations: { ResourceTypes.ResourceMutation } = {}
	local rateAtCommit: number? = nil
	local publicChanges: number = 0
	local propertySawCommit: boolean = false

	fixture.resources:_observeMutations({
		Commit = function(touched: { ResourceTypes.ResourceMutation })
			mutations = touched

			local state: ResourceTypes.ResourceReplicationState? =
				fixture.resources:_getReplicationState("Resource.Mana")

			rateAtCommit = if state ~= nil then state.regenRate else nil
		end,
		Dispatch = function() end,
	})

	fixture.resources.OnResourceChanged:Connect(function()
		publicChanges += 1
	end)

	fixture.properties.OnResolvedPropertyChanged:Connect(function()
		propertySawCommit = #mutations == 1
	end)

	expect(fixture.properties:SetBaseProperty("ManaRegen", 25)).toBe(true)
	expect(mutations).toEqual({ { resourceId = "Resource.Mana", kind = "Recomputed" } })
	expect(rateAtCommit).toBe(25)
	expect(propertySawCommit).toBe(true)
	expect(publicChanges).toBe(0)
end)

it("tags built-in stepping as RegenStep while keeping explicit Restore discrete", function()
	local mutations: { ResourceTypes.ResourceMutation } = {}

	fixture.resources:_observeMutations({
		Commit = function(touched: { ResourceTypes.ResourceMutation })
			for _, mutation: ResourceTypes.ResourceMutation in touched do
				table.insert(mutations, mutation)
			end
		end,
		Dispatch = function() end,
	})

	fixture.resources:Step(0.1)
	expect(#mutations > 0).toBe(true)

	for _, mutation: ResourceTypes.ResourceMutation in mutations do
		expect(mutation.kind).toBe("RegenStep")
	end

	table.clear(mutations)
	expect(fixture.resources:Restore("Resource.Mana", 1)).toBe(true)
	expect(mutations).toEqual({ { resourceId = "Resource.Mana", kind = "Discrete" } })
end)

it("commits one deterministic net touched set for nested batches before consumer dispatch", function()
	local batches: { { ResourceTypes.ResourceMutation } } = {}
	local values: { { number? } } = {}
	local publicChanges: number = 0

	fixture.resources:_observeMutations({
		Commit = function(touched: { ResourceTypes.ResourceMutation })
			table.insert(batches, touched)

			table.insert(
				values,
				{ fixture.resources:GetCurrent("Resource.Mana"), fixture.resources:GetCurrent("Resource.Stamina") }
			)
		end,
		Dispatch = function() end,
	})

	fixture.resources.OnResourceChanged:Connect(function()
		publicChanges += 1
	end)

	fixture.resources:_beginMutationBatch()
	expect(fixture.resources:Spend("Resource.Stamina", 5)).toBe(true)
	fixture.resources:_beginMutationBatch()
	expect(fixture.resources:Spend("Resource.Mana", 5)).toBe(true)
	expect(fixture.resources:Spend("Resource.Mana", 10)).toBe(true)
	fixture.resources:_finishMutationBatch()
	expect(batches).toEqual({})
	expect(publicChanges).toBe(0)
	fixture.resources:_finishMutationBatch()

	expect(batches).toEqual({
		{
			{ resourceId = "Resource.Mana", kind = "Discrete" },
			{ resourceId = "Resource.Stamina", kind = "Discrete" },
		},
	})

	expect(values).toEqual({ { 25, 15 } })
	expect(publicChanges).toBe(0)
	fixture.resources:_dispatchChanges()
	expect(publicChanges).toBe(2)
	expect(#batches).toBe(1)
end)

it("does not observe rejected, no-op or unrelated mutations", function()
	local commits: number = 0

	fixture.resources:_observeMutations({
		Commit = function()
			commits += 1
		end,
		Dispatch = function() end,
	})

	local spent: boolean, spendReason: string? = fixture.resources:Spend("Resource.Mana", 1000)
	expect(spent).toBe(false)
	expect(spendReason).toBe("InsufficientResourceValue")
	local changed: boolean, changeReason: string? = fixture.resources:SetCurrent("Resource.Mana", 0 / 0)
	expect(changed).toBe(false)
	expect(changeReason).toBe("InvalidResourceValue")
	local added: boolean, addReason: string? = fixture.resources:AddResource("Resource.Mana")
	expect(added).toBe(false)
	expect(addReason).toBe("ResourceAlreadyAssigned")
	expect(fixture.resources:SetCurrent("Resource.Mana", 40)).toBe(true)
	expect(fixture.resources:Restore("Resource.Mana", 0)).toBe(true)
	expect(fixture.properties:SetBaseProperty("Unrelated", 12)).toBe(true)
	fixture.resources:_beginMutationBatch()
	fixture.resources:_finishMutationBatch()
	fixture.resources:_dispatchChanges()
	expect(commits).toBe(0)
end)

it("disconnects idempotently and releases observation on controller teardown", function()
	local commits: number = 0

	local disconnect = fixture.resources:_observeMutations({
		Commit = function()
			commits += 1
		end,
		Dispatch = function() end,
	})

	expect(fixture.resources:Spend("Resource.Mana", 1)).toBe(true)
	expect(commits).toBe(1)
	disconnect()
	disconnect()
	expect(fixture.resources:Spend("Resource.Mana", 1)).toBe(true)
	expect(commits).toBe(1)
	fixture.resources:Destroy()
	disconnect()
end)
