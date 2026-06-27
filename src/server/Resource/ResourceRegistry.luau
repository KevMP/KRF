--!strict
local ResourceTypes = require(script.Parent.types)
local ResourceValidator = require(script.Parent.utils.ResourceValidator)
local ResourceDefinitionNormalizer = require(script.Parent.utils.ResourceDefinitionNormalizer)

type ResourceRegistry = ResourceTypes.ResourceRegistry
type ResourceDefinition = ResourceTypes.ResourceDefinition
type LoadedResourceDefinition = ResourceTypes.LoadedResourceDefinition

local ResourceRegistry = {} :: ResourceRegistry
local isLoaded: boolean = false
local definitionsById: { [string]: LoadedResourceDefinition } = {}
local orderedDefinitions: { LoadedResourceDefinition } = {}

function ResourceRegistry.Load(definitions: { ResourceDefinition }): (boolean, string?)
	if isLoaded then
		return false, "ResourceDefinitionsAlreadyLoaded"
	end

	local stagedDefinitionsById: { [string]: LoadedResourceDefinition } = {}
	local stagedOrderedDefinitions: { LoadedResourceDefinition } = {}
	local stagedRawDefinitionsById: { [string]: ResourceDefinition } = {}

	for _, definition: ResourceDefinition in definitions do
		local isValid: boolean, reason: string? =
			ResourceValidator.ValidateResourceDefinition(definition, stagedRawDefinitionsById)

		if not isValid then
			return false, reason
		end

		local loadedDefinition: LoadedResourceDefinition =
			ResourceDefinitionNormalizer.NormalizeResourceDefinition(definition)

		stagedRawDefinitionsById[definition.id] = definition
		stagedDefinitionsById[loadedDefinition.id] = loadedDefinition
		table.insert(stagedOrderedDefinitions, loadedDefinition)
	end

	definitionsById = stagedDefinitionsById
	orderedDefinitions = stagedOrderedDefinitions

	table.freeze(definitionsById)
	table.freeze(orderedDefinitions)

	isLoaded = true
	return true, nil
end

function ResourceRegistry.Get(resourceId: string): LoadedResourceDefinition?
	return definitionsById[resourceId]
end

function ResourceRegistry.GetAll(): { LoadedResourceDefinition }
	return orderedDefinitions
end

function ResourceRegistry.GetAllById(): { [string]: LoadedResourceDefinition }
	return definitionsById
end

function ResourceRegistry.IsLoaded(): boolean
	return isLoaded
end

function ResourceRegistry._resetForTests(): ()
	isLoaded = false
	definitionsById = {}
	orderedDefinitions = {}
end

return ResourceRegistry
