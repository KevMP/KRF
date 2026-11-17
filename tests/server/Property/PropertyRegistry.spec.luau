--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals = require(ReplicatedStorage.DevPackages.JestGlobals)
local it = JestGlobals.it
local expect = JestGlobals.expect
local Registry = require(KRF.server.Property.PropertyRegistry)
local PropertyTypes = require(KRF.server.Property.types)

JestGlobals.beforeEach(Registry._resetForTests)
JestGlobals.afterEach(Registry._resetForTests)

it("loads built-ins and normalizes game assignment without publishing during preparation", function()
	local prepared, reason = Registry.Prepare({
		{ id = "WalkSpeed", defaultBaseValue = 24 },
		{ id = "JumpPower", defaultBaseValue = 60, autoAssign = false },
		{ id = "Defense", defaultBaseValue = 10 },
		{ id = "Armor", defaultBaseValue = 20, autoAssign = true },
	})

	expect(reason).toBeNil()
	expect(Registry.IsLoaded()).toBe(false)
	expect(Registry.Get("WalkSpeed")).toBeNil()
	assert(prepared ~= nil, "Expected prepared Property catalog")
	expect(prepared.definitionsById.WalkSpeed.autoAssign).toBe(true)
	expect(prepared.definitionsById.JumpPower.autoAssign).toBe(false)
	expect(prepared.definitionsById.Defense.autoAssign).toBe(false)
	expect(prepared.definitionsById.Armor.autoAssign).toBe(true)
	local loaded, loadReason = Registry.Publish(prepared)
	expect(loaded).toBe(true)
	expect(loadReason).toBeNil()
	expect(Registry.GetAll()[1].id).toBe("WalkSpeed")
	expect(Registry.GetAll()[2].id).toBe("JumpPower")
	expect(Registry.GetAll()[3].id).toBe("Defense")
end)

it("owns frozen definitions and containers isolated from authored mutation", function()
	local definition: PropertyTypes.PropertyDefinition = { id = "Defense", defaultBaseValue = 20 }
	local definitions: { PropertyTypes.PropertyDefinition } = { definition }
	local loaded, reason = Registry.Load(definitions)
	expect(loaded).toBe(true)
	expect(reason).toBeNil()
	definition.defaultBaseValue = 999
	definitions[1] = { id = "Other", defaultBaseValue = 1 }

	local stored = Registry.Get("Defense")
	assert(stored ~= nil, "Expected registered Defense")
	expect(stored.defaultBaseValue).toBe(20)
	expect(Registry.Get("Other")).toBeNil()
	expect(table.isfrozen(stored)).toBe(true)
	expect(table.isfrozen(Registry.GetAll())).toBe(true)
	expect(table.isfrozen(Registry.GetAllById())).toBe(true)
	expect(Registry.GetAllById().Defense).toBe(stored)

	expect((pcall(function()
		stored.defaultBaseValue = 2
	end))).toBe(false)
end)

local invalidCases: { { name: string, definitions: any, reason: string } } = {
	{ name = "non-table", definitions = false, reason = "PropertyDefinitionsMustBeTable" },
	{ name = "map", definitions = { Defense = {} }, reason = "PropertyDefinitionsMustBeArray" },
	{ name = "sparse array", definitions = { [2] = {} }, reason = "PropertyDefinitionsMustBeArray" },
	{ name = "non-table entry", definitions = { false }, reason = "PropertyDefinitionMustBeTable" },
	{ name = "missing ID", definitions = { { defaultBaseValue = 0 } }, reason = "InvalidPropertyId" },
	{ name = "empty ID", definitions = { { id = "", defaultBaseValue = 0 } }, reason = "InvalidPropertyId" },
	{
		name = "nonnumeric default",
		definitions = { { id = "A", defaultBaseValue = "0" } },
		reason = "PropertyDefaultBaseValueMustBeFiniteNumber",
	},
	{ name = "missing default", definitions = { { id = "A" } }, reason = "PropertyDefaultBaseValueMustBeFiniteNumber" },
	{
		name = "infinity",
		definitions = { { id = "A", defaultBaseValue = math.huge } },
		reason = "PropertyDefaultBaseValueMustBeFiniteNumber",
	},
	{
		name = "NaN",
		definitions = { { id = "A", defaultBaseValue = 0 / 0 } },
		reason = "PropertyDefaultBaseValueMustBeFiniteNumber",
	},
	{
		name = "assignment shape",
		definitions = { { id = "A", defaultBaseValue = 0, autoAssign = 1 } },
		reason = "PropertyAutoAssignMustBeBoolean",
	},
	{
		name = "unknown field",
		definitions = { { id = "A", defaultBaseValue = 0, metadata = {} } },
		reason = "PropertyDefinitionFieldUnsupported",
	},
}

for _, case in invalidCases do
	it("rejects " .. case.name .. " without publishing built-ins or game entries", function()
		local loaded, reason = Registry.Load(case.definitions)
		expect(loaded).toBe(false)
		expect(reason).toBe(case.reason)
		expect(Registry.IsLoaded()).toBe(false)
		expect(Registry.GetAll()).toEqual({})
		expect(Registry.GetAllById()).toEqual({})
	end)
end

for _, id in { "WalkSpeed", "Defense" } do
	it("rejects duplicate game occurrences of " .. id .. " atomically", function()
		local loaded, reason = Registry.Load({
			{ id = id, defaultBaseValue = 1 },
			{ id = id, defaultBaseValue = 2 },
		})

		expect(loaded).toBe(false)
		expect(reason).toBe("PropertyIdAlreadyRegistered")
		expect(Registry.IsLoaded()).toBe(false)
	end)
end

it("loads only once and releases the entire catalog during rollback", function()
	local prepared = Registry.Prepare({})
	assert(prepared ~= nil, "Expected prepared Property catalog")
	assert(Registry.Load({}))
	expect((Registry.Get("WalkSpeed") :: PropertyTypes.PropertyDefinition).defaultBaseValue).toBe(16)
	expect((Registry.Get("JumpPower") :: PropertyTypes.PropertyDefinition).defaultBaseValue).toBe(50)
	local loaded, reason = Registry.Load({})
	expect(loaded).toBe(false)
	expect(reason).toBe("PropertyDefinitionsAlreadyLoaded")
	local published, publishReason = Registry.Publish(prepared)
	expect(published).toBe(false)
	expect(publishReason).toBe("PropertyDefinitionsAlreadyLoaded")
	Registry._RollbackStartup()
	expect(Registry.IsLoaded()).toBe(false)
	expect(Registry.Get("WalkSpeed")).toBeNil()
	expect((Registry.Load({}))).toBe(true)
end)
