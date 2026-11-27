--!strict
local Types = require(script.Parent.types)
local ActionRequestTypes = require(script.Parent.Parent.Parent.shared.ActionRequest.types)
local Collections = require(script.Parent.Parent.Parent.shared.Networking.utils.SchemaCollectionUtils)

local POLICY_FIELDS: { [string]: boolean } = {
	requiredTags = true,
	blockedTags = true,
	resourceRequirements = true,
	costs = true,
	canPredictStart = true,
}

local REQUIREMENT_FIELDS: { [string]: boolean } = { min = true, max = true, minPercent = true, maxPercent = true }
local COST_FIELDS: { [string]: boolean } = { amount = true, percent = true, multiplierProperty = true }

table.freeze(POLICY_FIELDS)
table.freeze(REQUIREMENT_FIELDS)
table.freeze(COST_FIELDS)

local Validator = {}

local function plain(value: any): boolean
	return type(value) == "table" and getmetatable(value) == nil
end

local function finite(value: any): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function tags(value: any, seen: { [string]: boolean }): ({ string }?, string?)
	local copied: { string } = {}

	if value == nil then
		return table.freeze(copied), nil
	end

	local length: number? = Collections.GetArrayLength(value)

	if length == nil or getmetatable(value) ~= nil then
		return nil, "ActionPredictionPolicyTagsInvalid"
	end

	for index: number = 1, length do
		local tagId: any = rawget(value, index)

		if type(tagId) ~= "string" or tagId == "" then
			return nil, "ActionPredictionPolicyTagsInvalid"
		elseif seen[tagId] then
			return nil, "ActionPredictionPolicyTagDuplicate"
		end

		seen[tagId] = true
		table.insert(copied, tagId)
	end

	return table.freeze(copied), nil
end

local function requirements(value: any): ({ [string]: Types.ActionPredictionResourceRequirement }?, string?)
	local copied: { [string]: Types.ActionPredictionResourceRequirement } = {}

	if value == nil then
		return table.freeze(copied), nil
	elseif not plain(value) then
		return nil, "ActionPredictionPolicyRequirementsInvalid"
	end

	for resourceId: any, requirement: any in next, value do
		if type(resourceId) ~= "string" or resourceId == "" or not plain(requirement) then
			return nil, "ActionPredictionPolicyRequirementInvalid"
		end

		local count: number = 0

		for field: any, threshold: any in next, requirement do
			if type(field) ~= "string" or not REQUIREMENT_FIELDS[field] or not finite(threshold) then
				return nil, "ActionPredictionPolicyRequirementInvalid"
			elseif (field == "minPercent" or field == "maxPercent") and (threshold < 0 or threshold > 1) then
				return nil, "ActionPredictionPolicyRequirementInvalid"
			end

			count += 1
		end

		if
			count == 0
			or (requirement.min ~= nil and requirement.max ~= nil and requirement.min > requirement.max)
			or (
				requirement.minPercent ~= nil
				and requirement.maxPercent ~= nil
				and requirement.minPercent > requirement.maxPercent
			)
		then
			return nil, "ActionPredictionPolicyRequirementInvalid"
		end

		copied[resourceId] = table.freeze({
			min = requirement.min,
			max = requirement.max,
			minPercent = requirement.minPercent,
			maxPercent = requirement.maxPercent,
		})
	end

	return table.freeze(copied), nil
end

local function costs(value: any): ({ [string]: Types.ActionPredictionResourceCost }?, string?)
	local copied: { [string]: Types.ActionPredictionResourceCost } = {}

	if value == nil then
		return table.freeze(copied), nil
	elseif not plain(value) then
		return nil, "ActionPredictionPolicyCostsInvalid"
	end

	for resourceId: any, cost: any in next, value do
		if type(resourceId) ~= "string" or resourceId == "" then
			return nil, "ActionPredictionPolicyCostInvalid"
		end

		local amount: any = cost
		local percent: any = nil
		local multiplier: any = nil

		if type(cost) == "table" then
			if getmetatable(cost) ~= nil then
				return nil, "ActionPredictionPolicyCostInvalid"
			end

			for field: any in next, cost do
				if type(field) ~= "string" or not COST_FIELDS[field] then
					return nil, "ActionPredictionPolicyCostInvalid"
				end
			end

			amount, percent, multiplier = cost.amount, cost.percent, cost.multiplierProperty

			if (amount ~= nil) == (percent ~= nil) then
				return nil, "ActionPredictionPolicyCostInvalid"
			elseif multiplier ~= nil and (type(multiplier) ~= "string" or multiplier == "") then
				return nil, "ActionPredictionPolicyCostInvalid"
			end
		end

		local quantity: any = if amount ~= nil then amount else percent

		if not finite(quantity) or quantity <= 0 then
			return nil, "ActionPredictionPolicyCostInvalid"
		end

		copied[resourceId] = table.freeze({ amount = amount, percent = percent, multiplierProperty = multiplier })
	end

	return table.freeze(copied), nil
end

local function compile(actionId: string, policy: any): (Types.CompiledActionPredictionPolicy?, string?)
	if not plain(policy) then
		return nil, "ActionPredictionPolicyInvalid"
	end

	for field: any in next, policy do
		if type(field) ~= "string" or not POLICY_FIELDS[field] then
			return nil, "ActionPredictionPolicyFieldUnknown"
		end
	end

	local callback: any = policy.canPredictStart

	if callback ~= nil and type(callback) ~= "function" then
		return nil, "ActionPredictionPolicyCallbackInvalid"
	end

	local seen: { [string]: boolean } = {}
	local required: { string }?, requiredReason: string? = tags(policy.requiredTags, seen)

	if required == nil then
		return nil, requiredReason
	end

	local blocked: { string }?, blockedReason: string? = tags(policy.blockedTags, seen)

	if blocked == nil then
		return nil, blockedReason
	end

	local resourceRequirements, requirementReason = requirements(policy.resourceRequirements)

	if resourceRequirements == nil then
		return nil, requirementReason
	end

	local resourceCosts, costReason = costs(policy.costs)

	if resourceCosts == nil then
		return nil, costReason
	end

	local referenced: { [string]: boolean } = {}
	local resourceIds: { string } = {}

	for resourceId: string in resourceRequirements do
		referenced[resourceId] = true
	end

	for resourceId: string in resourceCosts do
		referenced[resourceId] = true
	end

	for resourceId: string in referenced do
		table.insert(resourceIds, resourceId)
	end

	table.sort(resourceIds)

	return table.freeze({
		actionId = actionId,
		requiredTags = required,
		blockedTags = blocked,
		resourceIds = table.freeze(resourceIds),
		resourceRequirements = resourceRequirements,
		costs = resourceCosts,
		canPredictStart = callback,
	}),
		nil
end

function Validator.Compile(
	value: any,
	requests: ActionRequestTypes.ActionRequestCatalog?
): (Types.ActionPredictionPolicyCatalog?, string?)
	local compiled: Types.ActionPredictionPolicyCatalog = {}

	if value == nil then
		return table.freeze(compiled), nil
	elseif not plain(value) then
		return nil, "ActionPredictionPoliciesInvalid"
	end

	for actionId: any, policy: any in next, value do
		if type(actionId) ~= "string" or actionId == "" then
			return nil, "ActionPredictionPolicyIdInvalid"
		elseif requests == nil or requests.requestsById[actionId] == nil then
			return nil, "ActionPredictionPolicyActionUnknown"
		end

		local entry: Types.CompiledActionPredictionPolicy?, reason: string? = compile(actionId, policy)

		if entry == nil then
			return nil, reason
		end

		compiled[actionId] = entry
	end

	return table.freeze(compiled), nil
end

return table.freeze(Validator)
