--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local Types = require(KRF.client.Presentation.types)
local Validator = require(KRF.client.Presentation.HintPredictionPolicyValidator)

local function reasonFor(value: any): string?
	local compiled: Types.HintPredictionPolicyCatalog?, reason: string? = Validator.Compile(value)

	expect(compiled).toBeNil()

	return reason
end

it("compiles omitted and empty policies to an empty frozen catalog", function()
	for _, value: any in { nil, {} } do
		local compiled: Types.HintPredictionPolicyCatalog = assert(Validator.Compile(value))

		expect(compiled).toEqual({})
		expect(table.isfrozen(compiled)).toBe(true)
	end
end)

it("copies each policy so later caller mutation cannot change the installed source fields", function()
	local policy: { [string]: string } = { actorIdField = "attackerId", sequenceIdField = "sequenceId" }
	local compiled: Types.HintPredictionPolicyCatalog = assert(Validator.Compile({ ["Punch.Impact"] = policy }))

	policy.actorIdField = "victimId"

	expect(compiled["Punch.Impact"]).toEqual({ actorIdField = "attackerId", sequenceIdField = "sequenceId" })
	expect(table.isfrozen(compiled["Punch.Impact"])).toBe(true)
end)

it("rejects a non-table catalog and invalid Hint ids", function()
	expect(reasonFor("Punch.Impact")).toBe("HintPredictionPoliciesInvalid")
	expect(reasonFor(setmetatable({}, {}))).toBe("HintPredictionPoliciesInvalid")
	expect(reasonFor({ [""] = { actorIdField = "a", sequenceIdField = "b" } })).toBe("HintPredictionPolicyIdInvalid")
	expect(reasonFor({ { actorIdField = "a", sequenceIdField = "b" } })).toBe("HintPredictionPolicyIdInvalid")
end)

it("rejects policies that are not plain tables or declare unknown fields", function()
	expect(reasonFor({ Impact = true })).toBe("HintPredictionPolicyInvalid")

	expect(reasonFor({ Impact = { actorIdField = "a", sequenceIdField = "b", targetField = "c" } })).toBe(
		"HintPredictionPolicyFieldUnknown"
	)
end)

it("requires two distinct nonempty payload field names for the source Actor and activation", function()
	local invalid: { any } = {
		{},
		{ actorIdField = "attackerId" },
		{ sequenceIdField = "sequenceId" },
		{ actorIdField = "", sequenceIdField = "sequenceId" },
		{ actorIdField = 1, sequenceIdField = "sequenceId" },
		{ actorIdField = "source", sequenceIdField = "source" },
	}

	for _, policy: any in invalid do
		expect(reasonFor({ Impact = policy })).toBe("HintPredictionPolicySourceInvalid")
	end
end)
