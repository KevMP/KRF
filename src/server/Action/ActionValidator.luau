--!strict
local ActionTypes = require(script.Parent.types)

type ActionDefinition = ActionTypes.ActionDefinition

local SUPPORTED_FIELDS: { [string]: boolean } = {
	id = true,
	visibility = true,
	autoGrant = true,
	requiredTags = true,
	blockedTags = true,
	costs = true,
	locks = true,
	interruptibleBy = true,
	onCanStart = true,
	onStart = true,
	onUpdate = true,
	onEnd = true,
	onInterrupt = true,
	canBeInterruptedBy = true,
}
table.freeze(SUPPORTED_FIELDS)

local HOOK_FIELDS: { string } = {
	"onCanStart",
	"onStart",
	"onUpdate",
	"onEnd",
	"onInterrupt",
	"canBeInterruptedBy",
}
table.freeze(HOOK_FIELDS)

local ActionValidator = {}

local function ValidateIdentity(definition: any): (boolean, string?)
	if definition == nil then
		return false, "ActionDefinitionMissing"
	end
	if type(definition) ~= "table" then
		return false, "ActionDefinitionMustBeTable"
	end
	if definition.id == nil then
		return false, "ActionIdMissing"
	end
	if type(definition.id) ~= "string" then
		return false, "ActionIdMustBeString"
	end
	if definition.id == "" then
		return false, "ActionIdCannotBeEmpty"
	end
	return true, nil
end

local function ValidateArray(value: any, prefix: string): (boolean, string?)
	if type(value) ~= "table" then
		return false, `{prefix}MustBeTable`
	end
	local count: number = 0
	for key in value do
		if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
			return false, `{prefix}MustBeArray`
		end
		count += 1
	end
	for index: number = 1, count do
		if value[index] == nil then
			return false, `{prefix}MustBeArray`
		end
	end
	return true, nil
end

local function ValidateIdList(
	value: any,
	fieldPrefix: string,
	idPrefix: string,
	preparedIds: { [string]: boolean }?,
	unknownPrefix: string
): (boolean, string?)
	if value == nil then
		return true, nil
	end
	local valid: boolean, reason: string? = ValidateArray(value, fieldPrefix)
	if not valid then
		return false, reason
	end
	local seen: { [string]: boolean } = {}
	for _, id in value do
		if type(id) ~= "string" then
			return false, `{idPrefix}MustBeString`
		end
		if id == "" then
			return false, `{idPrefix}CannotBeEmpty`
		end
		if seen[id] then
			return false, `{idPrefix}Duplicate`
		end
		seen[id] = true
		if preparedIds ~= nil and not preparedIds[id] then
			return false, `{unknownPrefix}:{id}`
		end
	end
	return true, nil
end

local function ValidateCosts(costs: any, preparedResourceIds: { [string]: boolean }): (boolean, string?)
	if costs == nil then
		return true, nil
	end
	if type(costs) ~= "table" then
		return false, "ActionCostsMustBeTable"
	end
	local resourceIds: { string } = {}
	for resourceId in costs do
		if type(resourceId) ~= "string" then
			return false, "ActionCostResourceIdMustBeString"
		end
		table.insert(resourceIds, resourceId)
	end
	table.sort(resourceIds)
	for _, resourceId: string in resourceIds do
		if resourceId == "" then
			return false, "ActionCostResourceIdCannotBeEmpty"
		end
		local amount: any = costs[resourceId]
		if type(amount) ~= "number" then
			return false, "ActionCostMustBeNumber"
		end
		if not math.isfinite(amount) then
			return false, "ActionCostMustBeFiniteNumber"
		end
		if amount <= 0 then
			return false, "ActionCostMustBePositive"
		end
		if not preparedResourceIds[resourceId] then
			return false, `ActionCostResourceUnknown:{resourceId}`
		end
	end
	return true, nil
end

function ActionValidator.ValidateActionDefinition(
	definition: unknown,
	preparedActionIds: { [string]: boolean },
	preparedTagIds: { [string]: boolean },
	preparedResourceIds: { [string]: boolean }
): (boolean, string?)
	local valid: boolean, reason: string? = ValidateIdentity(definition)
	if not valid then
		return false, reason
	end
	local fields: { [string]: any } = definition :: any
	local unsupportedFields: { string } = {}
	for field in fields do
		if type(field) ~= "string" then
			return false, "ActionFieldMustBeString"
		end
		if not SUPPORTED_FIELDS[field] then
			table.insert(unsupportedFields, field)
		end
	end
	if #unsupportedFields > 0 then
		table.sort(unsupportedFields)
		return false, `ActionFieldUnsupported:{unsupportedFields[1]}`
	end
	if fields.visibility == nil then
		return false, "ActionVisibilityMissing"
	end
	if type(fields.visibility) ~= "string" then
		return false, "ActionVisibilityMustBeString"
	end
	if fields.visibility ~= "ServerOnly" and fields.visibility ~= "ClientVisible" then
		return false, "ActionVisibilityInvalid"
	end
	if fields.autoGrant ~= nil and type(fields.autoGrant) ~= "boolean" then
		return false, "ActionAutoGrantMustBeBoolean"
	end
	for _, field: string in HOOK_FIELDS do
		if fields[field] ~= nil and type(fields[field]) ~= "function" then
			return false, `Action{string.upper(string.sub(field, 1, 1))}{string.sub(field, 2)}MustBeFunction`
		end
	end
	valid, reason = ValidateIdList(
		fields.requiredTags,
		"ActionRequiredTags",
		"ActionRequiredTagId",
		preparedTagIds,
		"ActionRequiredTagUnknown"
	)
	if not valid then
		return false, reason
	end
	valid, reason = ValidateIdList(
		fields.blockedTags,
		"ActionBlockedTags",
		"ActionBlockedTagId",
		preparedTagIds,
		"ActionBlockedTagUnknown"
	)
	if not valid then
		return false, reason
	end
	local requiredTags: { [string]: boolean } = {}
	for _, tagId: string in fields.requiredTags or {} do
		requiredTags[tagId] = true
	end
	for _, tagId: string in fields.blockedTags or {} do
		if requiredTags[tagId] then
			return false, `ActionRequiredAndBlockedTagsOverlap:{tagId}`
		end
	end
	valid, reason = ValidateCosts(fields.costs, preparedResourceIds)
	if not valid then
		return false, reason
	end
	valid, reason = ValidateIdList(fields.locks, "ActionLocks", "ActionLockId", nil, "")
	if not valid then
		return false, reason
	end
	return ValidateIdList(
		fields.interruptibleBy,
		"ActionInterruptibleBy",
		"ActionInterruptibleById",
		preparedActionIds,
		"ActionInterruptibleByUnknown"
	)
end

function ActionValidator.ValidateCatalog(
	definitions: { ActionDefinition },
	preparedTagIds: { [string]: boolean },
	preparedResourceIds: { [string]: boolean }
): (boolean, string?)
	local valid: boolean, reason: string? = ValidateArray(definitions, "ActionDefinitions")
	if not valid then
		return false, reason
	end
	local preparedActionIds: { [string]: boolean } = {}
	for _, definition: ActionDefinition in definitions do
		valid, reason = ValidateIdentity(definition)
		if not valid then
			return false, reason
		end
		if preparedActionIds[definition.id] then
			return false, "ActionIdAlreadyRegistered"
		end
		preparedActionIds[definition.id] = true
	end
	for _, definition: ActionDefinition in definitions do
		valid, reason =
			ActionValidator.ValidateActionDefinition(definition, preparedActionIds, preparedTagIds, preparedResourceIds)
		if not valid then
			return false, reason
		end
	end
	return true, nil
end

return ActionValidator
