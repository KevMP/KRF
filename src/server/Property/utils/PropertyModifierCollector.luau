--!strict

local propertyFolder = script.Parent.Parent
local serverFolder = propertyFolder.Parent

local TagRegistry = require(serverFolder.Tags.TagRegistry)
local TagTypes = require(serverFolder.Tags.types)
local PropertyResolver = require(propertyFolder.utils.PropertyResolver)

local PropertyModifierCollector = {}

function PropertyModifierCollector.CollectForProperty(
	tagController: TagTypes.TagController?,
	propertyName: string
): { PropertyResolver.ModifierEntry }
	local modifierEntries: { PropertyResolver.ModifierEntry } = {}

	if tagController == nil then
		return modifierEntries
	end

	for _, activeTag: TagTypes.ActiveTagSnapshot in tagController:GetActiveTags() do
		local tagDefinition: TagTypes.TagDefinition? = TagRegistry.Get(activeTag.tagId)

		if tagDefinition == nil or tagDefinition.properties == nil then
			continue
		end

		local modifier: TagTypes.PropertyModifier? = tagDefinition.properties[propertyName]

		if modifier ~= nil then
			table.insert(modifierEntries, {
				tagId = activeTag.tagId,
				modifier = modifier,
				stackCount = activeTag.stackCount,
			})
		end
	end

	return modifierEntries
end

function PropertyModifierCollector.GetAffectedPropertyNames(tagId: string): { string }
	local propertyNames: { string } = {}
	local tagDefinition: TagTypes.TagDefinition? = TagRegistry.Get(tagId)

	if tagDefinition == nil or tagDefinition.properties == nil then
		return propertyNames
	end

	for propertyName: string in tagDefinition.properties do
		table.insert(propertyNames, propertyName)
	end

	return propertyNames
end

return PropertyModifierCollector
