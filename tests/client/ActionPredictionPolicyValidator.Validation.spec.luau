--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local Types = require(KRF.client.Presentation.types)
local Validator = require(KRF.client.Presentation.ActionPredictionPolicyValidator)
local PredictionUtils = require(script.Parent.Utils.PresentationPredictionTestUtils)

local function reasonFor(value: any): string?
	local compiled: Types.ActionPredictionPolicyCatalog?, reason: string? =
		Validator.Compile(value, PredictionUtils.catalog)

	expect(compiled).toBeNil()

	return reason
end

it("compiles omitted and empty policies to an empty frozen catalog", function()
	local omitted: Types.ActionPredictionPolicyCatalog = assert(Validator.Compile(nil, PredictionUtils.catalog))
	local empty: Types.ActionPredictionPolicyCatalog = assert(Validator.Compile({}, PredictionUtils.catalog))

	for _, compiled: Types.ActionPredictionPolicyCatalog in { omitted, empty } do
		expect(compiled).toEqual({})
		expect(table.isfrozen(compiled)).toBe(true)
	end
end)

it("compiles an empty policy for a registered request Action as declaring no client checks", function()
	local compiled: Types.ActionPredictionPolicyCatalog =
		assert(Validator.Compile({ Dash = {} }, PredictionUtils.catalog))

	expect(compiled.Dash).toEqual({
		actionId = "Dash",
		requiredTags = {},
		blockedTags = {},
		resourceIds = {},
		resourceRequirements = {},
		costs = {},
	})
end)

it("copies every declared gate so later caller mutation cannot change the installed policy", function()
	local required: { string } = { "Status.Grounded" }
	local mana: { [string]: number } = { min = 30 }
	local percentCost: { [string]: any } = { percent = 0.25 }

	local check = function(): boolean?
		return true
	end

	local compiled: Types.ActionPredictionPolicyCatalog = assert(Validator.Compile({
		Fireball = {
			requiredTags = required,
			blockedTags = { "Status.Stunned" },
			resourceRequirements = { Mana = mana, Stamina = { minPercent = 0.5, maxPercent = 1 } },
			costs = { Mana = 20, Stamina = percentCost, Charges = { amount = 1, multiplierProperty = "Haste" } },
			canPredictStart = check,
		},
	}, PredictionUtils.catalog))

	required[1] = "Changed"
	mana.min = 999
	percentCost.percent = 0.9

	local policy: Types.CompiledActionPredictionPolicy = compiled.Fireball
	expect(policy.requiredTags).toEqual({ "Status.Grounded" })
	expect(policy.blockedTags).toEqual({ "Status.Stunned" })
	expect(policy.resourceIds).toEqual({ "Charges", "Mana", "Stamina" })
	expect(policy.resourceRequirements.Mana).toEqual({ min = 30 })
	expect(policy.costs.Mana).toEqual({ amount = 20 })
	expect(policy.costs.Stamina).toEqual({ percent = 0.25 })
	expect(policy.costs.Charges).toEqual({ amount = 1, multiplierProperty = "Haste" })
	expect(policy.canPredictStart).toBe(check)
	expect(table.isfrozen(policy)).toBe(true)
	expect(table.isfrozen(policy.requiredTags)).toBe(true)
	expect(table.isfrozen(policy.costs.Stamina)).toBe(true)
end)

it("rejects Action IDs outside the compiled local request schema catalog", function()
	expect(reasonFor({ Unregistered = {} })).toBe("ActionPredictionPolicyActionUnknown")
	expect(reasonFor({ [""] = {} })).toBe("ActionPredictionPolicyIdInvalid")
	expect(reasonFor({ [1] = {} })).toBe("ActionPredictionPolicyIdInvalid")
	expect({ Validator.Compile({ Dash = {} }, nil) }).toEqual({ nil, "ActionPredictionPolicyActionUnknown" })
end)

it("rejects malformed policy tables and unknown fields without calling the callback", function()
	local calls: number = 0

	local callback = function(): boolean?
		calls += 1

		return true
	end

	expect(reasonFor(false)).toBe("ActionPredictionPoliciesInvalid")
	expect(reasonFor(setmetatable({}, {}))).toBe("ActionPredictionPoliciesInvalid")
	expect(reasonFor({ Dash = false })).toBe("ActionPredictionPolicyInvalid")
	expect(reasonFor({ Dash = { onCanStart = callback } })).toBe("ActionPredictionPolicyFieldUnknown")
	expect(reasonFor({ Dash = { canPredictStart = true } })).toBe("ActionPredictionPolicyCallbackInvalid")

	expect(reasonFor({ Dash = { canPredictStart = callback, costs = { Mana = 0 } } })).toBe(
		"ActionPredictionPolicyCostInvalid"
	)

	expect(calls).toBe(0)
end)

it("rejects malformed and duplicate Tag declarations", function()
	expect(reasonFor({ Dash = { requiredTags = "Status.Grounded" } })).toBe("ActionPredictionPolicyTagsInvalid")
	expect(reasonFor({ Dash = { requiredTags = { "" } } })).toBe("ActionPredictionPolicyTagsInvalid")
	expect(reasonFor({ Dash = { blockedTags = { [2] = "Gap" } } })).toBe("ActionPredictionPolicyTagsInvalid")
	expect(reasonFor({ Dash = { requiredTags = { "A", "A" } } })).toBe("ActionPredictionPolicyTagDuplicate")

	expect(reasonFor({ Dash = { requiredTags = { "A" }, blockedTags = { "A" } } })).toBe(
		"ActionPredictionPolicyTagDuplicate"
	)
end)

it("rejects Resource requirements that the server validator would also reject", function()
	local invalid: { any } = {
		{ Mana = false },
		{ Mana = {} },
		{ Mana = { minimum = 1 } },
		{ Mana = { min = "1" } },
		{ Mana = { min = math.huge } },
		{ Mana = { minPercent = 1.5 } },
		{ Mana = { maxPercent = -0.1 } },
		{ Mana = { min = 5, max = 1 } },
		{ Mana = { minPercent = 0.8, maxPercent = 0.2 } },
		{ [""] = { min = 1 } },
	}

	for _, requirements: any in invalid do
		expect(reasonFor({ Dash = { resourceRequirements = requirements } })).toBe(
			"ActionPredictionPolicyRequirementInvalid"
		)
	end

	expect(reasonFor({ Dash = { resourceRequirements = 5 } })).toBe("ActionPredictionPolicyRequirementsInvalid")
end)

it("rejects costs without exactly one positive finite amount or percent", function()
	local invalid: { any } = {
		{ Mana = -1 },
		{ Mana = 0 },
		{ Mana = 0 / 0 },
		{ Mana = "5" },
		{ Mana = {} },
		{ Mana = { amount = 1, percent = 0.5 } },
		{ Mana = { amount = 1, multiplier = "Haste" } },
		{ Mana = { amount = 1, multiplierProperty = "" } },
		{ Mana = setmetatable({ amount = 1 }, {}) },
		{ [""] = 1 },
	}

	for _, costs: any in invalid do
		expect(reasonFor({ Dash = { costs = costs } })).toBe("ActionPredictionPolicyCostInvalid")
	end

	expect(reasonFor({ Dash = { costs = true } })).toBe("ActionPredictionPolicyCostsInvalid")
end)
