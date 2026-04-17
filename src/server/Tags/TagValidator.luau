--!strict
local RegistryTypes = require(script.Parent.types)

export type TagRegistry = RegistryTypes.TagRegistry
export type TagDefinition = RegistryTypes.TagDefinition
export type TagVisibility = RegistryTypes.TagVisibility
export type PropertyModifier = RegistryTypes.PropertyModifier

local VALID_DUPLICATE_BEHAVIORS = table.freeze({
	Stack = true,
	Refresh = true,
	Ignore = true,
})

local VALID_VISIBILITIES = table.freeze({
	ServerOnly = true,
	ClientVisible = true,
})

local VALID_PROPERTY_MODIFIER_KEYS = table.freeze({
	set = true,
	add = true,
	multiply = true,
	min = true,
	max = true,
})

local TagValidator = {}

local function ValidateTagId(tagDefinition: TagDefinition, loadedTags: { [string]: TagDefinition }): (boolean, string?)
	if tagDefinition.id == nil then
		return false, "TagIdMissing"
	end

	if type(tagDefinition.id) ~= "string" then
		return false, "TagIdMustBeString"
	end

	if tagDefinition.id == "" then
		return false, "TagIdCannotBeEmpty"
	end

	if loadedTags[tagDefinition.id] ~= nil then
		return false, "TagIdAlreadyRegistered"
	end

	return true, nil
end

local function ValidateTagDefaultDuration(tagDefinition: TagDefinition): (boolean, string?)
	if tagDefinition.defaultDuration == nil then
		return true, nil
	end

	if type(tagDefinition.defaultDuration) ~= "number" then
		return false, "TagDefaultDurationMustBeNumber"
	end

	if tagDefinition.defaultDuration <= 0 then
		return false, "TagDefaultDurationMustBePositive"
	end

	return true, nil
end

local function ValidateTagTickInterval(tagDefinition: TagDefinition): (boolean, string?)
	if tagDefinition.tickInterval == nil then
		return true, nil
	end

	if type(tagDefinition.tickInterval) ~= "number" then
		return false, "TagTickIntervalMustBeNumber"
	end

	if tagDefinition.tickInterval <= 0 then
		return false, "TagTickIntervalMustBePositive"
	end

	return true, nil
end

local function ValidateTagDuplicateBehavior(tagDefinition: TagDefinition): (boolean, string?)
	if tagDefinition.duplicateBehavior == nil then
		return false, "TagDuplicateBehaviorMissing"
	end

	if type(tagDefinition.duplicateBehavior) ~= "string" then
		return false, "TagDuplicateBehaviorMustBeString"
	end

	if not VALID_DUPLICATE_BEHAVIORS[tagDefinition.duplicateBehavior] then
		return false, "TagDuplicateBehaviorInvalid"
	end

	return true, nil
end

local function ValidateTagMaxStacks(tagDefinition: TagDefinition): (boolean, string?)
	if tagDefinition.maxStacks == nil then
		return true, nil
	end

	if type(tagDefinition.maxStacks) ~= "number" then
		return false, "TagMaxStacksMustBeNumber"
	end

	if tagDefinition.maxStacks <= 0 then
		return false, "TagMaxStacksMustBePositive"
	end

	if tagDefinition.maxStacks % 1 ~= 0 then
		return false, "TagMaxStacksMustBeInteger"
	end

	if tagDefinition.duplicateBehavior ~= "Stack" then
		return false, "TagMaxStacksRequiresStackDuplicateBehavior"
	end

	return true, nil
end

local function ValidateTagVisibility(tagDefinition: TagDefinition): (boolean, string?)
	if tagDefinition.visibility == nil then
		return false, "TagVisibilityMissing"
	end

	if type(tagDefinition.visibility) ~= "string" then
		return false, "TagVisibilityMustBeString"
	end

	if not VALID_VISIBILITIES[tagDefinition.visibility] then
		return false, "TagVisibilityInvalid"
	end

	return true, nil
end

local function ValidateTagOnTick(tagDefinition: TagDefinition): (boolean, string?)
	if tagDefinition.onTick == nil then
		return true, nil
	end

	if type(tagDefinition.onTick) ~= "function" then
		return false, "TagOnTickMustBeFunction"
	end

	return true, nil
end

local function ValidatePropertyModifier(modifier: PropertyModifier): (boolean, string?)
	if type(modifier) ~= "table" then
		return false, "TagPropertyModifierMustBeTable"
	end

	local hasAnyModifierField: boolean = false

	for modifierKey: string, modifierValue: any in modifier do
		if not VALID_PROPERTY_MODIFIER_KEYS[modifierKey] then
			return false, "TagPropertyModifierFieldInvalid"
		end

		if type(modifierValue) ~= "number" then
			return false, "TagPropertyModifierValueMustBeNumber"
		end

		hasAnyModifierField = true
	end

	if not hasAnyModifierField then
		return false, "TagPropertyModifierCannotBeEmpty"
	end

	if modifier.set ~= nil then
		if modifier.add ~= nil or modifier.multiply ~= nil or modifier.min ~= nil or modifier.max ~= nil then
			return false, "TagPropertyModifierSetCannotBeCombined"
		end
	end

	return true, nil
end

local function ValidateTagProperties(tagDefinition: TagDefinition): (boolean, string?)
	if tagDefinition.properties == nil then
		return true, nil
	end

	if type(tagDefinition.properties) ~= "table" then
		return false, "TagPropertiesMustBeTable"
	end

	for propertyName: string, modifier: PropertyModifier in tagDefinition.properties do
		if type(propertyName) ~= "string" then
			return false, "TagPropertyNameMustBeString"
		end

		if propertyName == "" then
			return false, "TagPropertyNameCannotBeEmpty"
		end

		local isModifierValid: boolean, modifierFailReason: string? = ValidatePropertyModifier(modifier)

		if not isModifierValid then
			return false, modifierFailReason
		end
	end

	return true, nil
end

function TagValidator.ValidateTagDefinition(
	tagDefinition: TagDefinition,
	loadedTags: { [string]: TagDefinition }
): (boolean, string?)
	if tagDefinition == nil then
		return false, "TagDefinitionMissing"
	end

	if type(tagDefinition) ~= "table" then
		return false, "TagDefinitionMustBeTable"
	end

	local isTagIdValid: boolean, tagIdFailReason: string? = ValidateTagId(tagDefinition, loadedTags)
	if not isTagIdValid then
		return false, tagIdFailReason
	end

	local isTagDefaultDurationValid: boolean, tagDefaultDurationFailReason: string? =
		ValidateTagDefaultDuration(tagDefinition)
	if not isTagDefaultDurationValid then
		return false, tagDefaultDurationFailReason
	end

	local isTagTickIntervalValid: boolean, tagTickIntervalFailReason: string? = ValidateTagTickInterval(tagDefinition)
	if not isTagTickIntervalValid then
		return false, tagTickIntervalFailReason
	end

	local isTagDuplicateBehaviorValid: boolean, tagDuplicateBehaviorFailReason: string? =
		ValidateTagDuplicateBehavior(tagDefinition)
	if not isTagDuplicateBehaviorValid then
		return false, tagDuplicateBehaviorFailReason
	end

	local isTagMaxStacksValid: boolean, tagMaxStacksFailReason: string? = ValidateTagMaxStacks(tagDefinition)
	if not isTagMaxStacksValid then
		return false, tagMaxStacksFailReason
	end

	local isTagVisibilityValid: boolean, tagVisibilityFailReason: string? = ValidateTagVisibility(tagDefinition)
	if not isTagVisibilityValid then
		return false, tagVisibilityFailReason
	end

	local isTagOnTickValid: boolean, tagOnTickFailReason: string? = ValidateTagOnTick(tagDefinition)
	if not isTagOnTickValid then
		return false, tagOnTickFailReason
	end

	local isTagPropertiesValid: boolean, tagPropertiesFailReason: string? = ValidateTagProperties(tagDefinition)
	if not isTagPropertiesValid then
		return false, tagPropertiesFailReason
	end

	return true, nil
end

return TagValidator
