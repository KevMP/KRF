--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local ActionRegistry = require(KRF.server.Action.ActionRegistry)
local ActionTypes = require(KRF.server.Action.types)

type ActionDefinition = ActionTypes.ActionDefinition
type ActionResourceRequirement = ActionTypes.ActionResourceRequirement
type ActionResourceCost = ActionTypes.ActionResourceCost
local resourceIds: { [string]: boolean } = { Mana = true, Chakra = true, Stamina = true }

beforeEach(function()
	ActionRegistry._resetForTests()
end)
afterEach(function()
	ActionRegistry._resetForTests()
end)

local function load(definition: ActionDefinition): (boolean, string?)
	return ActionRegistry.Load({
		function(): ActionDefinition
			return definition
		end,
	}, {}, resourceIds)
end

local function expectInvalid(definition: ActionDefinition): ()
	local loaded: boolean, reason: string? = load(definition)
	expect(loaded).toBe(false)
	expect(type(reason)).toBe("string")
	expect(reason).never.toBe("")
	-- An unsupported top-level field is not validation of its nested contract.
	expect(reason).never.toBe("ActionFieldUnsupported:resourceRequirements")
	expect(ActionRegistry.IsLoaded()).toBe(false)
	expect(ActionRegistry.GetAll()).toEqual({})
	expect(ActionRegistry.GetAllById()).toEqual({})
	local repeated: boolean, repeatedReason: string? = load(definition)
	expect(repeated).toBe(false)
	expect(repeatedReason).toBe(reason)
end

local validRequirements: { { name: string, value: ActionResourceRequirement } } = {
	{ name = "a finite negative absolute minimum", value = { min = -20 } },
	{ name = "an absolute maximum", value = { max = 80 } },
	{ name = "equal absolute thresholds", value = { min = 20, max = 20 } },
	{ name = "a zero relative minimum", value = { minPercent = 0 } },
	{ name = "a full relative maximum", value = { maxPercent = 1 } },
	{ name = "equal relative thresholds", value = { minPercent = 0.5, maxPercent = 0.5 } },
	{
		name = "all four requirement constraints",
		value = { min = 20, max = 100, minPercent = 0.25, maxPercent = 0.75 },
	},
}
for _, case in validRequirements do
	it("accepts " .. case.name, function()
		local loaded: boolean, reason: string? = load({
			id = "Cast",
			visibility = "ServerOnly",
			resourceRequirements = { Mana = case.value },
		})
		expect(loaded).toBe(true)
		expect(reason).toBeNil()
	end)
end

local invalidRequirements: { { name: string, value: any } } = {
	{ name = "a boolean requirement", value = false },
	{ name = "a numeric requirement", value = 20 },
	{ name = "a string requirement", value = "20" },
	{ name = "a requirement without constraints", value = {} },
	{ name = "a string absolute minimum", value = { min = "20" } },
	{ name = "a boolean absolute maximum", value = { max = false } },
	{ name = "an infinite absolute minimum", value = { min = math.huge } },
	{ name = "a negative infinite absolute maximum", value = { max = -math.huge } },
	{ name = "a NaN absolute minimum", value = { min = 0 / 0 } },
	{ name = "a NaN absolute maximum", value = { max = 0 / 0 } },
	{ name = "a string relative minimum", value = { minPercent = "0.5" } },
	{ name = "a boolean relative maximum", value = { maxPercent = false } },
	{ name = "a relative minimum below zero", value = { minPercent = -0.01 } },
	{ name = "a relative minimum above one", value = { minPercent = 1.01 } },
	{ name = "a relative maximum below zero", value = { maxPercent = -0.01 } },
	{ name = "a relative maximum above one", value = { maxPercent = 1.01 } },
	{ name = "an infinite relative minimum", value = { minPercent = math.huge } },
	{ name = "a negative infinite relative maximum", value = { maxPercent = -math.huge } },
	{ name = "a NaN relative minimum", value = { minPercent = 0 / 0 } },
	{ name = "a NaN relative maximum", value = { maxPercent = 0 / 0 } },
	{ name = "inverted absolute thresholds", value = { min = 20, max = 10 } },
	{ name = "inverted relative thresholds", value = { minPercent = 0.75, maxPercent = 0.25 } },
	{ name = "unknown requirement fields", value = { min = 20, unsupported = true } },
	{ name = "numeric requirement fields", value = { min = 20, [1] = 10 } },
}
for _, case in invalidRequirements do
	it("rejects " .. case.name .. " before publication", function()
		expectInvalid({ id = "Cast", visibility = "ServerOnly", resourceRequirements = { Mana = case.value } })
	end)
end

local validCosts: { { name: string, value: number | ActionResourceCost } } = {
	{ name = "numeric shorthand", value = 20 },
	{ name = "fractional shorthand", value = 0.125 },
	{ name = "a structured fixed amount", value = { amount = 20 } },
	{ name = "a structured percentage", value = { percent = 0.25 } },
	{ name = "a percentage greater than one", value = { percent = 2 } },
	{ name = "a fixed amount multiplier", value = { amount = 20, multiplierProperty = "ManaCostMultiplier" } },
	{ name = "a percentage multiplier", value = { percent = 0.25, multiplierProperty = "ManaCostMultiplier" } },
}
for _, case in validCosts do
	it("accepts " .. case.name .. " without requiring Actor Properties at startup", function()
		local loaded: boolean, reason: string? =
			load({ id = "Cast", visibility = "ServerOnly", costs = { Mana = case.value } })
		expect(loaded).toBe(true)
		expect(reason).toBeNil()
	end)
end

local invalidCosts: { { name: string, value: any } } = {
	{ name = "zero shorthand", value = 0 },
	{ name = "negative shorthand", value = -1 },
	{ name = "infinite shorthand", value = math.huge },
	{ name = "negative infinite shorthand", value = -math.huge },
	{ name = "NaN shorthand", value = 0 / 0 },
	{ name = "a boolean cost", value = false },
	{ name = "a string cost", value = "20" },
	{ name = "an empty structured cost", value = {} },
	{ name = "both amount and percent", value = { amount = 20, percent = 0.25 } },
	{ name = "a multiplier without amount or percent", value = { multiplierProperty = "Multiplier" } },
	{ name = "a zero amount", value = { amount = 0 } },
	{ name = "a negative amount", value = { amount = -1 } },
	{ name = "an infinite amount", value = { amount = math.huge } },
	{ name = "a negative infinite amount", value = { amount = -math.huge } },
	{ name = "a NaN amount", value = { amount = 0 / 0 } },
	{ name = "a zero percentage", value = { percent = 0 } },
	{ name = "a negative percentage", value = { percent = -1 } },
	{ name = "an infinite percentage", value = { percent = math.huge } },
	{ name = "a negative infinite percentage", value = { percent = -math.huge } },
	{ name = "a NaN percentage", value = { percent = 0 / 0 } },
	{ name = "a string amount", value = { amount = "20" } },
	{ name = "a boolean percentage", value = { percent = false } },
	{ name = "an empty multiplier name", value = { amount = 20, multiplierProperty = "" } },
	{ name = "a boolean multiplier name", value = { amount = 20, multiplierProperty = false } },
	{ name = "a numeric multiplier name", value = { percent = 0.25, multiplierProperty = 1 } },
	{ name = "unknown cost fields", value = { amount = 20, refund = true } },
	{ name = "numeric cost fields", value = { percent = 0.25, [1] = 10 } },
}
for _, case in invalidCosts do
	it("rejects " .. case.name .. " before publication", function()
		expectInvalid({ id = "Cast", visibility = "ServerOnly", costs = { Mana = case.value } })
	end)
end

for _, field: string in { "resourceRequirements", "costs" } do
	for index: number, collection: any in { false, 20, "Mana" } do
		it("rejects a non-table " .. field .. " collection " .. index, function()
			local definition: any = { id = "Cast", visibility = "ServerOnly" }
			definition[field] = collection
			expectInvalid(definition)
		end)
	end
	for index: number, resourceId: any in { "", 1, "Unknown" } do
		it("rejects invalid or unknown Resource ids in " .. field .. " " .. index, function()
			local definition: any = { id = "Cast", visibility = "ServerOnly" }
			definition[field] = { [resourceId] = if field == "costs" then { amount = 20 } else { min = 20 } }
			expectInvalid(definition)
		end)
	end
end

it("copies and freezes Resource metadata without freezing consumer source tables", function()
	local requirement: ActionResourceRequirement = { min = 20, minPercent = 0.25 }
	local cost: ActionResourceCost = { amount = 10, multiplierProperty = "Multiplier" }
	local percentageCost: ActionResourceCost = { percent = 0.25 }
	local definition: ActionDefinition = {
		id = "Cast",
		visibility = "ServerOnly",
		resourceRequirements = { Mana = requirement },
		costs = { Mana = cost, Chakra = percentageCost, Stamina = 5 },
	}
	local loaded: boolean, reason: string? = load(definition)
	expect(loaded).toBe(true)
	expect(reason).toBeNil()
	requirement.min = 80
	requirement.minPercent = 0.75
	cost.amount = 90
	cost.multiplierProperty = "OtherMultiplier"
	percentageCost.percent = 0.75
	(definition.resourceRequirements :: { [string]: ActionResourceRequirement }).Chakra = { max = 0 }
	(definition.costs :: { [string]: number | ActionResourceCost }).Stamina = 50
	local catalog: ActionTypes.LoadedActionDefinition = ActionRegistry.Get("Cast") :: ActionTypes.LoadedActionDefinition
	expect(catalog.resourceRequirements).toEqual({ Mana = { min = 20, minPercent = 0.25 } })
	expect(catalog.costs).toEqual({
		Mana = { amount = 10, multiplierProperty = "Multiplier" },
		Chakra = { percent = 0.25 },
		Stamina = 5,
	})
	expect(table.isfrozen(requirement)).toBe(false)
	expect(table.isfrozen(cost)).toBe(false)
	expect(table.isfrozen(percentageCost)).toBe(false)
	local requirements = catalog.resourceRequirements :: { [string]: ActionResourceRequirement }
	expect(table.isfrozen(requirements)).toBe(true)
	expect(table.isfrozen(requirements.Mana)).toBe(true)
	expect(table.isfrozen(catalog.costs)).toBe(true)
	expect(table.isfrozen(catalog.costs.Mana :: ActionResourceCost)).toBe(true)
	expect(table.isfrozen(catalog.costs.Chakra :: ActionResourceCost)).toBe(true)
	expect(ActionRegistry.GetAll()[1]).toBe(catalog)
	expect(ActionRegistry.GetAllById().Cast).toBe(catalog)
end)

it("does not publish a partial catalog when a later definition has invalid Resource metadata", function()
	local prepared: ActionTypes.PreparedActionCatalog?, reason: string? = ActionRegistry.Prepare({
		function(): ActionDefinition
			return { id = "Valid", visibility = "ServerOnly", costs = { Mana = 10 } }
		end,
		function(): ActionDefinition
			return { id = "Invalid", visibility = "ServerOnly", costs = { Chakra = { amount = 0 } } }
		end,
	}, {}, resourceIds)
	expect(prepared).toBeNil()
	expect(type(reason)).toBe("string")
	expect(ActionRegistry.IsLoaded()).toBe(false)
	expect(ActionRegistry.Get("Valid")).toBeNil()
end)
