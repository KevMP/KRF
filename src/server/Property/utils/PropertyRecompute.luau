--!strict

local propertyFolder = script.Parent.Parent

local PropertyResolver = require(propertyFolder.utils.PropertyResolver)
local PropertyModifierCollector = require(script.Parent.PropertyModifierCollector)
local TagTypes = require(propertyFolder.Parent.Tags.types)

local PropertyRecompute = {}

export type PropertyRecord = {
	baseValue: number,
	resolvedValue: number,
}

export type ResolvedChange = {
	propertyName: string,
	oldBaseValue: number,
	newBaseValue: number,
	oldResolvedValue: number,
	newResolvedValue: number,
}

export type PropertyRecordsById = {
	[string]: PropertyRecord,
}

function PropertyRecompute.RecomputeProperty(
	propertiesById: PropertyRecordsById,
	tagController: TagTypes.TagController?,
	propertyName: string
): ResolvedChange?
	local propertyRecord = propertiesById[propertyName]

	if propertyRecord == nil then
		return nil
	end

	local oldResolvedValue = propertyRecord.resolvedValue
	local modifierEntries = PropertyModifierCollector.CollectForProperty(tagController, propertyName)
	local newResolvedValue = PropertyResolver.Resolve(propertyRecord.baseValue, modifierEntries)

	if oldResolvedValue == newResolvedValue then
		return nil
	end

	propertyRecord.resolvedValue = newResolvedValue

	return {
		propertyName = propertyName,
		oldBaseValue = propertyRecord.baseValue,
		newBaseValue = propertyRecord.baseValue,
		oldResolvedValue = oldResolvedValue,
		newResolvedValue = newResolvedValue,
	}
end

function PropertyRecompute.RecomputePropertiesAffectedByTag(
	propertiesById: PropertyRecordsById,
	tagController: TagTypes.TagController?,
	tagId: string
): { ResolvedChange }
	local changes: { ResolvedChange } = {}
	local affectedPropertyNames = PropertyModifierCollector.GetAffectedPropertyNames(tagId)

	for _, propertyName in affectedPropertyNames do
		if propertiesById[propertyName] == nil then
			continue
		end

		local change = PropertyRecompute.RecomputeProperty(propertiesById, tagController, propertyName)

		if change ~= nil then
			table.insert(changes, change)
		end
	end

	return changes
end

return PropertyRecompute
