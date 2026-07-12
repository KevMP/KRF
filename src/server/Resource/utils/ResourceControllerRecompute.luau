--!strict
local serverFolder = script.Parent.Parent.Parent

local PropertyTypes = require(serverFolder.Property.types)
local ResourceTypes = require(serverFolder.Resource.types)
local ResourceStateResolver = require(script.Parent.ResourceStateResolver)

type LoadedResourceDefinition = ResourceTypes.LoadedResourceDefinition
type PropertyController = PropertyTypes.PropertyController
type ResourceNumericSource = ResourceTypes.ResourceNumericSource

export type ResourceRecord = {
	definition: LoadedResourceDefinition,
	currentValue: number,
	resolvedMin: number,
	resolvedMax: number,
	resolvedRegenRate: number?,
}

export type ResourceRecordsById = { [string]: ResourceRecord }
export type ResourceIdsByPropertyName = { [string]: { [string]: boolean } }
export type ResourceRecomputeChange = {
	resourceId: string,
	currentOldValue: number,
	currentNewValue: number,
	minOldValue: number,
	minNewValue: number,
	maxOldValue: number,
	maxNewValue: number,
}

local ResourceControllerRecomputeUtils = {}

local function indexPropertySource(
	resourceIdsByPropertyName: ResourceIdsByPropertyName,
	resourceId: string,
	source: ResourceNumericSource
): ()
	local propertyName: string? = source.propertyName
	if propertyName == nil then
		return
	end

	local resourceIds: { [string]: boolean } = resourceIdsByPropertyName[propertyName] or {}
	resourceIdsByPropertyName[propertyName] = resourceIds
	resourceIds[resourceId] = true
end

local function recomputeResource(
	resourcesById: ResourceRecordsById,
	propertyController: PropertyController,
	resourceId: string
): ResourceRecomputeChange?
	local resourceRecord: ResourceRecord? = resourcesById[resourceId]
	if resourceRecord == nil then
		return nil
	end

	local resolvedMin: number?, resolvedMax: number?, resolvedRegenRate: number? =
		ResourceStateResolver.Resolve(propertyController, resourceRecord.definition)
	if resolvedMin == nil or resolvedMax == nil then
		return nil
	end

	local previousCurrentValue: number = resourceRecord.currentValue
	local previousResolvedMin: number = resourceRecord.resolvedMin
	local previousResolvedMax: number = resourceRecord.resolvedMax

	resourceRecord.resolvedMin = resolvedMin
	resourceRecord.resolvedMax = resolvedMax
	resourceRecord.resolvedRegenRate = resolvedRegenRate
	resourceRecord.currentValue = math.clamp(resourceRecord.currentValue, resolvedMin, resolvedMax)

	if
		previousCurrentValue == resourceRecord.currentValue
		and previousResolvedMin == resourceRecord.resolvedMin
		and previousResolvedMax == resourceRecord.resolvedMax
	then
		return nil
	end

	return {
		resourceId = resourceId,
		currentOldValue = previousCurrentValue,
		currentNewValue = resourceRecord.currentValue,
		minOldValue = previousResolvedMin,
		minNewValue = resourceRecord.resolvedMin,
		maxOldValue = previousResolvedMax,
		maxNewValue = resourceRecord.resolvedMax,
	}
end

function ResourceControllerRecomputeUtils.IndexPropertySources(
	resourceIdsByPropertyName: ResourceIdsByPropertyName,
	definition: LoadedResourceDefinition
): ()
	indexPropertySource(resourceIdsByPropertyName, definition.id, definition.min)
	indexPropertySource(resourceIdsByPropertyName, definition.id, definition.max)

	if definition.regen ~= nil then
		indexPropertySource(resourceIdsByPropertyName, definition.id, definition.regen.rate)
	end
end

function ResourceControllerRecomputeUtils.RecomputeResourcesAffectedByProperty(
	resourcesById: ResourceRecordsById,
	resourceIdsByPropertyName: ResourceIdsByPropertyName,
	propertyController: PropertyController,
	propertyName: string
): { ResourceRecomputeChange }
	local resourceIds: { [string]: boolean }? = resourceIdsByPropertyName[propertyName]
	if resourceIds == nil then
		return {}
	end

	local orderedResourceIds: { string } = {}
	for resourceId: string in resourceIds do
		table.insert(orderedResourceIds, resourceId)
	end
	table.sort(orderedResourceIds)

	local changes: { ResourceRecomputeChange } = {}
	for _, resourceId: string in orderedResourceIds do
		local change: ResourceRecomputeChange? = recomputeResource(resourcesById, propertyController, resourceId)
		if change ~= nil then
			table.insert(changes, change)
		end
	end

	return changes
end

return ResourceControllerRecomputeUtils
