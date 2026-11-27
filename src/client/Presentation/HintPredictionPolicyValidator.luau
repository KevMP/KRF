--!strict
local Types = require(script.Parent.types)

local POLICY_FIELDS: { [string]: boolean } = { actorIdField = true, sequenceIdField = true }

table.freeze(POLICY_FIELDS)

local Validator = {}

local function plain(value: any): boolean
	return type(value) == "table" and getmetatable(value) == nil
end

local function field(value: any): boolean
	return type(value) == "string" and value ~= ""
end

local function compile(policy: any): (Types.HintPredictionPolicy?, string?)
	if not plain(policy) then
		return nil, "HintPredictionPolicyInvalid"
	end

	for name: any in next, policy do
		if type(name) ~= "string" or not POLICY_FIELDS[name] then
			return nil, "HintPredictionPolicyFieldUnknown"
		end
	end

	local actorIdField: any = policy.actorIdField
	local sequenceIdField: any = policy.sequenceIdField

	if not field(actorIdField) or not field(sequenceIdField) or actorIdField == sequenceIdField then
		return nil, "HintPredictionPolicySourceInvalid"
	end

	return table.freeze({ actorIdField = actorIdField, sequenceIdField = sequenceIdField }), nil
end

function Validator.Compile(value: any): (Types.HintPredictionPolicyCatalog?, string?)
	local compiled: Types.HintPredictionPolicyCatalog = {}

	if value == nil then
		return table.freeze(compiled), nil
	elseif not plain(value) then
		return nil, "HintPredictionPoliciesInvalid"
	end

	for hintId: any, policy: any in next, value do
		if type(hintId) ~= "string" or hintId == "" then
			return nil, "HintPredictionPolicyIdInvalid"
		end

		local entry: Types.HintPredictionPolicy?, reason: string? = compile(policy)

		if entry == nil then
			return nil, reason
		end

		compiled[hintId] = entry
	end

	return table.freeze(compiled), nil
end

return table.freeze(Validator)
