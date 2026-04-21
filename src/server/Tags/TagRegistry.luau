--!strict
local RegistryTypes = require(script.Parent.types)
local TagValidator = require(script.Parent.TagValidator)

export type TagRegistry = RegistryTypes.TagRegistry
export type TagDefinition = RegistryTypes.TagDefinition

local TagRegistry = {} :: TagRegistry
local isLoaded: boolean = false
local definitionsById: { [string]: TagDefinition } = {}
local orderedDefinitions: { TagDefinition } = {}

function TagRegistry.Load(definitions: { TagDefinition }): (boolean, string?)
	if isLoaded then
		return false, "TagDefinitionsAlreadyLoded"
	end

	local stagedDefinitionsById: { [string]: TagDefinition } = {}
	local stagedOrderedDefinitions: { TagDefinition } = {}

	for _, definition: TagDefinition in definitions do
		local isvalid: boolean, reason: string? = TagValidator.ValidateTagDefinition(definition, stagedDefinitionsById)

		if not isvalid then
			return false, reason
		end

		stagedDefinitionsById[definition.id] = definition
		table.insert(stagedOrderedDefinitions, definition)
	end

	definitionsById = stagedDefinitionsById
	orderedDefinitions = stagedOrderedDefinitions

	table.freeze(definitionsById)
	table.freeze(orderedDefinitions)

	isLoaded = true
	return true, nil
end

function TagRegistry.Get(tagId: string): TagDefinition?
	return definitionsById[tagId]
end

function TagRegistry.GetAll(): { TagDefinition }
	return orderedDefinitions
end

function TagRegistry.GetAllById(): { [string]: TagDefinition }
	return definitionsById
end

function TagRegistry.IsLoaded(): boolean
	return isLoaded
end

function TagRegistry._resetForTests(): ()
	isLoaded = false
	definitionsById = {}
	orderedDefinitions = {}
end

return TagRegistry
