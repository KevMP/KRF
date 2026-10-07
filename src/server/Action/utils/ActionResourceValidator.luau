--!strict
local ActionResourceValidator = {}

local function resourceIds(value: any, prefix: string): ({ string }?, string?)
	if type(value) ~= "table" then
		return nil, prefix .. "MustBeTable"
	end
	local ids: { string } = {}
	for id in value do
		if type(id) ~= "string" then
			return nil, prefix .. "ResourceIdMustBeString"
		end
		table.insert(ids, id)
	end
	table.sort(ids)
	if ids[1] == "" then
		return nil, prefix .. "ResourceIdCannotBeEmpty"
	end
	return ids, nil
end

local function validateFields(value: any, supported: { [string]: boolean }, prefix: string): string?
	local unsupported: { string } = {}
	for key in value do
		if type(key) ~= "string" then
			return prefix .. "FieldMustBeString"
		end
		if not supported[key] then
			table.insert(unsupported, key)
		end
	end
	table.sort(unsupported)
	return if #unsupported > 0 then prefix .. "FieldUnsupported:" .. unsupported[1] else nil
end

function ActionResourceValidator.ValidateRequirements(
	requirements: any,
	preparedIds: { [string]: boolean }
): (boolean, string?)
	if requirements == nil then
		return true, nil
	end
	local ids: { string }?, reason: string? = resourceIds(requirements, "ActionResourceRequirements")
	if ids == nil then
		return false, reason
	end
	for _, id: string in ids do
		local requirement: any = requirements[id]
		if type(requirement) ~= "table" then
			return false, "ActionResourceRequirementMustBeTable:" .. id
		end
		local fieldReason: string? = validateFields(
			requirement,
			{ min = true, max = true, minPercent = true, maxPercent = true },
			"ActionResourceRequirement"
		)
		if fieldReason ~= nil then
			return false, fieldReason
		end
		local count: number = 0
		for _, field: string in { "min", "max", "minPercent", "maxPercent" } do
			local threshold: any = requirement[field]
			if threshold ~= nil then
				count += 1
				if type(threshold) ~= "number" or not math.isfinite(threshold) then
					return false, "ActionResourceRequirementThresholdInvalid:" .. id .. ":" .. field
				end
				if (field == "minPercent" or field == "maxPercent") and (threshold < 0 or threshold > 1) then
					return false, "ActionResourceRequirementPercentOutOfRange:" .. id
				end
			end
		end
		if count == 0 then
			return false, "ActionResourceRequirementConstraintsMissing:" .. id
		end
		if requirement.min ~= nil and requirement.max ~= nil and requirement.min > requirement.max then
			return false, "ActionResourceRequirementRangeInverted:" .. id
		end
		if
			requirement.minPercent ~= nil
			and requirement.maxPercent ~= nil
			and requirement.minPercent > requirement.maxPercent
		then
			return false, "ActionResourceRequirementPercentRangeInverted:" .. id
		end
		if not preparedIds[id] then
			return false, "ActionResourceRequirementResourceUnknown:" .. id
		end
	end
	return true, nil
end

function ActionResourceValidator.ValidateCosts(costs: any, preparedIds: { [string]: boolean }): (boolean, string?)
	if costs == nil then
		return true, nil
	end
	local ids: { string }?, reason: string? = resourceIds(costs, "ActionCost")
	if ids == nil then
		return false, if type(costs) ~= "table" then "ActionCostsMustBeTable" else reason
	end
	for _, id: string in ids do
		local cost: any = costs[id]
		local amount: any = cost
		if type(cost) == "table" then
			local fieldReason: string? =
				validateFields(cost, { amount = true, percent = true, multiplierProperty = true }, "ActionCost")
			if fieldReason ~= nil then
				return false, fieldReason
			end
			if (cost.amount ~= nil) == (cost.percent ~= nil) then
				return false, "ActionCostAmountOrPercentRequired:" .. id
			end
			amount = if cost.amount ~= nil then cost.amount else cost.percent
			if
				cost.multiplierProperty ~= nil
				and (type(cost.multiplierProperty) ~= "string" or cost.multiplierProperty == "")
			then
				return false, "ActionCostMultiplierPropertyInvalid:" .. id
			end
		end
		if type(amount) ~= "number" then
			return false, "ActionCostMustBeNumber"
		end
		if not math.isfinite(amount) then
			return false, "ActionCostMustBeFiniteNumber"
		end
		if amount <= 0 then
			return false, "ActionCostMustBePositive"
		end
		if not preparedIds[id] then
			return false, "ActionCostResourceUnknown:" .. id
		end
	end
	return true, nil
end

return ActionResourceValidator
