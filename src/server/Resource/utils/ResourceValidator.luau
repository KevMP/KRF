--!strict
local ResourceTypes = require(script.Parent.Parent.types)

type ResourceDefinition = ResourceTypes.ResourceDefinition
type ResourceNumericSource = ResourceTypes.ResourceNumericSource
type ResourceRegenDefinition = ResourceTypes.ResourceRegenDefinition

local VALID_VISIBILITIES = table.freeze({
	ServerOnly = true,
	ClientVisible = true,
}) :: { [string]: boolean }

local ResourceValidator = {}

local function ValidateFiniteNumber(value: any, numberReason: string, finiteNumberReason: string): (boolean, string?)
	if type(value) ~= "number" then
		return false, numberReason
	end

	if not math.isfinite(value) then
		return false, finiteNumberReason
	end

	return true, nil
end

local function ValidateResourceId(
	definition: ResourceDefinition,
	loadedResources: { [string]: ResourceDefinition }
): (boolean, string?)
	if definition.id == nil then
		return false, "ResourceIdMissing"
	end

	if type(definition.id) ~= "string" then
		return false, "ResourceIdMustBeString"
	end

	if definition.id == "" then
		return false, "ResourceIdCannotBeEmpty"
	end

	if loadedResources[definition.id] ~= nil then
		return false, "ResourceIdAlreadyRegistered"
	end

	return true, nil
end

local function ValidateResourceVisibility(definition: ResourceDefinition): (boolean, string?)
	if definition.visibility == nil then
		return false, "ResourceVisibilityMissing"
	end

	if type(definition.visibility) ~= "string" then
		return false, "ResourceVisibilityMustBeString"
	end

	if not VALID_VISIBILITIES[definition.visibility] then
		return false, "ResourceVisibilityInvalid"
	end

	return true, nil
end

local function ValidateResourceInitialValue(definition: ResourceDefinition): (boolean, string?)
	if definition.initialValue == nil then
		return true, nil
	end

	return ValidateFiniteNumber(
		definition.initialValue,
		"ResourceInitialValueMustBeNumber",
		"ResourceInitialValueMustBeFiniteNumber"
	)
end

local function ValidateResourceAutoAssign(definition: ResourceDefinition): (boolean, string?)
	if definition.autoAssign == nil then
		return true, nil
	end

	if type(definition.autoAssign) ~= "boolean" then
		return false, "ResourceAutoAssignMustBeBoolean"
	end

	return true, nil
end

local function ValidateNumericSource(source: ResourceNumericSource, sourcePrefix: string): (boolean, string?)
	if type(source) ~= "table" then
		return false, `{sourcePrefix}MustBeTable`
	end

	local sourceTable: { [string]: any } = source :: any
	local sourceValue: any = sourceTable.value
	local propertyName: any = sourceTable.propertyName
	local defaultBaseValue: any = sourceTable.defaultBaseValue

	local hasValue: boolean = sourceValue ~= nil
	local hasPropertyName: boolean = propertyName ~= nil

	if hasValue and hasPropertyName then
		return false, `{sourcePrefix}CannotUseValueAndPropertyNameTogether`
	end

	if not hasValue and not hasPropertyName then
		return false, `{sourcePrefix}MustProvideValueOrPropertyName`
	end

	if hasValue then
		local isSourceValueValid: boolean, sourceValueFailReason: string? = ValidateFiniteNumber(
			sourceValue,
			`{sourcePrefix}ValueMustBeNumber`,
			`{sourcePrefix}ValueMustBeFiniteNumber`
		)
		if not isSourceValueValid then
			return false, sourceValueFailReason
		end

		if defaultBaseValue ~= nil then
			return false, `{sourcePrefix}DefaultBaseValueRequiresPropertyName`
		end

		return true, nil
	end

	if type(propertyName) ~= "string" then
		return false, `{sourcePrefix}PropertyNameMustBeString`
	end

	if propertyName == "" then
		return false, `{sourcePrefix}PropertyNameCannotBeEmpty`
	end

	if defaultBaseValue == nil then
		return false, `{sourcePrefix}DefaultBaseValueMissing`
	end

	local isDefaultBaseValueValid: boolean, defaultBaseValueFailReason: string? = ValidateFiniteNumber(
		defaultBaseValue,
		`{sourcePrefix}DefaultBaseValueMustBeNumber`,
		`{sourcePrefix}DefaultBaseValueMustBeFiniteNumber`
	)
	if not isDefaultBaseValueValid then
		return false, defaultBaseValueFailReason
	end

	return true, nil
end

local function ValidateResourceMax(definition: ResourceDefinition): (boolean, string?)
	if definition.max == nil then
		return false, "ResourceMaxMissing"
	end

	return ValidateNumericSource(definition.max, "ResourceMax")
end

local function ValidateResourceMin(definition: ResourceDefinition): (boolean, string?)
	if definition.min == nil then
		return true, nil
	end

	return ValidateNumericSource(definition.min, "ResourceMin")
end

local function GetDefaultResolvedNumericSourceValue(source: ResourceNumericSource): number
	local sourceTable: { [string]: any } = source :: any

	if sourceTable.value ~= nil then
		return sourceTable.value
	end

	return sourceTable.defaultBaseValue
end

local function ValidateResourceRegen(regen: ResourceRegenDefinition?): (boolean, string?)
	if regen == nil then
		return true, nil
	end

	if type(regen) ~= "table" then
		return false, "ResourceRegenMustBeTable"
	end

	local regenTable: { [string]: any } = regen :: any
	local regenRate: ResourceNumericSource? = regenTable.rate

	if regenRate == nil then
		return false, "ResourceRegenRateMissing"
	end

	local isRegenRateValid: boolean, regenRateFailReason: string? =
		ValidateNumericSource(regenRate, "ResourceRegenRate")
	if not isRegenRateValid then
		return false, regenRateFailReason
	end

	local defaultResolvedRate: number = GetDefaultResolvedNumericSourceValue(regenRate)
	if defaultResolvedRate < 0 then
		return false, "ResourceRegenRateCannotBeNegative"
	end

	return true, nil
end

local function ValidateDefaultResolvedBounds(definition: ResourceDefinition): (boolean, string?)
	local defaultResolvedMin: number = 0

	if definition.min ~= nil then
		defaultResolvedMin = GetDefaultResolvedNumericSourceValue(definition.min)
	end

	local defaultResolvedMax: number = GetDefaultResolvedNumericSourceValue(definition.max)
	if defaultResolvedMax < defaultResolvedMin then
		return false, "ResourceDefaultMaxLessThanDefaultMin"
	end

	return true, nil
end

local function ValidateInitialValueWithinDefaultResolvedBounds(definition: ResourceDefinition): (boolean, string?)
	if definition.initialValue == nil then
		return true, nil
	end

	local defaultResolvedMin: number = 0

	if definition.min ~= nil then
		defaultResolvedMin = GetDefaultResolvedNumericSourceValue(definition.min)
	end

	local defaultResolvedMax: number = GetDefaultResolvedNumericSourceValue(definition.max)

	if definition.initialValue < defaultResolvedMin then
		return false, "ResourceInitialValueLessThanDefaultMin"
	end

	if definition.initialValue > defaultResolvedMax then
		return false, "ResourceInitialValueGreaterThanDefaultMax"
	end

	return true, nil
end

function ResourceValidator.ValidateResourceDefinition(
	definition: ResourceDefinition,
	loadedResources: { [string]: ResourceDefinition }
): (boolean, string?)
	if definition == nil then
		return false, "ResourceDefinitionMissing"
	end

	if type(definition) ~= "table" then
		return false, "ResourceDefinitionMustBeTable"
	end

	local isResourceIdValid: boolean, resourceIdFailReason: string? = ValidateResourceId(definition, loadedResources)
	if not isResourceIdValid then
		return false, resourceIdFailReason
	end

	local isResourceVisibilityValid: boolean, resourceVisibilityFailReason: string? =
		ValidateResourceVisibility(definition)
	if not isResourceVisibilityValid then
		return false, resourceVisibilityFailReason
	end

	local isResourceInitialValueValid: boolean, resourceInitialValueFailReason: string? =
		ValidateResourceInitialValue(definition)
	if not isResourceInitialValueValid then
		return false, resourceInitialValueFailReason
	end

	local isResourceAutoAssignValid: boolean, resourceAutoAssignFailReason: string? =
		ValidateResourceAutoAssign(definition)
	if not isResourceAutoAssignValid then
		return false, resourceAutoAssignFailReason
	end

	local isResourceMaxValid: boolean, resourceMaxFailReason: string? = ValidateResourceMax(definition)
	if not isResourceMaxValid then
		return false, resourceMaxFailReason
	end

	local isResourceMinValid: boolean, resourceMinFailReason: string? = ValidateResourceMin(definition)
	if not isResourceMinValid then
		return false, resourceMinFailReason
	end

	local isResourceRegenValid: boolean, resourceRegenFailReason: string? = ValidateResourceRegen(definition.regen)
	if not isResourceRegenValid then
		return false, resourceRegenFailReason
	end

	local isDefaultResolvedBoundsValid: boolean, defaultResolvedBoundsFailReason: string? =
		ValidateDefaultResolvedBounds(definition)
	if not isDefaultResolvedBoundsValid then
		return false, defaultResolvedBoundsFailReason
	end

	local isInitialValueWithinDefaultResolvedBoundsValid: boolean, initialValueWithinDefaultResolvedBoundsFailReason: string? =
		ValidateInitialValueWithinDefaultResolvedBounds(definition)
	if not isInitialValueWithinDefaultResolvedBoundsValid then
		return false, initialValueWithinDefaultResolvedBoundsFailReason
	end

	return true, nil
end

return ResourceValidator
