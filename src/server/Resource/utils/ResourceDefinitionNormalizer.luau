--!strict
local ResourceTypes = require(script.Parent.Parent.types)

type ResourceDefinition = ResourceTypes.ResourceDefinition
type ResourceNumericSource = ResourceTypes.ResourceNumericSource
type ResourceRegenDefinition = ResourceTypes.ResourceRegenDefinition
type LoadedResourceDefinition = ResourceTypes.LoadedResourceDefinition

local DEFAULT_MIN_SOURCE: ResourceNumericSource = table.freeze({
	value = 0,
}) :: ResourceNumericSource

local ResourceDefinitionNormalizer = {}

local function CloneNumericSource(source: ResourceNumericSource): ResourceNumericSource
	return table.freeze({
		value = source.value,
		propertyName = source.propertyName,
		defaultBaseValue = source.defaultBaseValue,
	}) :: ResourceNumericSource
end

local function CloneRegenDefinition(regen: ResourceRegenDefinition?): ResourceRegenDefinition?
	if regen == nil then
		return nil
	end

	return table.freeze({
		rate = CloneNumericSource(regen.rate),
	}) :: ResourceRegenDefinition
end

function ResourceDefinitionNormalizer.NormalizeResourceDefinition(
	definition: ResourceDefinition
): LoadedResourceDefinition
	local normalizedMin: ResourceNumericSource = DEFAULT_MIN_SOURCE

	if definition.min ~= nil then
		normalizedMin = CloneNumericSource(definition.min)
	end

	local normalizedMax: ResourceNumericSource = CloneNumericSource(definition.max)

	return table.freeze({
		id = definition.id,
		min = normalizedMin,
		max = normalizedMax,
		initialValue = definition.initialValue,
		visibility = definition.visibility,
		autoAssign = if definition.autoAssign ~= nil then definition.autoAssign else false,
		regen = CloneRegenDefinition(definition.regen),
	}) :: LoadedResourceDefinition
end

return ResourceDefinitionNormalizer
