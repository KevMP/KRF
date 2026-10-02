--!strict
local ActionTypes = require(script.Parent.types)
local ActionValidator = require(script.Parent.ActionValidator)

type ActionDefinition = ActionTypes.ActionDefinition
type ActionRegistry = ActionTypes.ActionRegistry
type LoadedActionDefinition = ActionTypes.LoadedActionDefinition

local ActionRegistry = {} :: ActionRegistry
local isLoaded: boolean = false
local definitionsById: { [string]: LoadedActionDefinition } = {}
local orderedDefinitions: { LoadedActionDefinition } = {}

table.freeze(definitionsById)
table.freeze(orderedDefinitions)

function ActionRegistry.Load(
	definitions: { ActionDefinition },
	preparedTagIds: { [string]: boolean },
	preparedResourceIds: { [string]: boolean }
): (boolean, string?)
	if isLoaded then
		return false, "ActionDefinitionsAlreadyLoaded"
	end
	local valid: boolean, reason: string? =
		ActionValidator.ValidateCatalog(definitions, preparedTagIds, preparedResourceIds)
	if not valid then
		return false, reason
	end

	local stagedDefinitionsById: { [string]: LoadedActionDefinition } = {}
	local stagedOrderedDefinitions: { LoadedActionDefinition } = {}
	for _, definition: ActionDefinition in definitions do
		local loadedDefinition: LoadedActionDefinition = table.freeze({
			id = definition.id,
			visibility = definition.visibility,
			autoGrant = if definition.autoGrant ~= nil then definition.autoGrant else false,
			requiredTags = table.freeze(table.clone(definition.requiredTags or {})),
			blockedTags = table.freeze(table.clone(definition.blockedTags or {})),
			costs = table.freeze(table.clone(definition.costs or {})),
			locks = table.freeze(table.clone(definition.locks or {})),
			interruptibleBy = table.freeze(table.clone(definition.interruptibleBy or {})),
			onCanStart = definition.onCanStart,
			onStart = definition.onStart,
			onUpdate = definition.onUpdate,
			onEnd = definition.onEnd,
			onInterrupt = definition.onInterrupt,
			canBeInterruptedBy = definition.canBeInterruptedBy,
		}) :: LoadedActionDefinition
		stagedDefinitionsById[loadedDefinition.id] = loadedDefinition
		table.insert(stagedOrderedDefinitions, loadedDefinition)
	end
	definitionsById = table.freeze(stagedDefinitionsById)
	orderedDefinitions = table.freeze(stagedOrderedDefinitions)
	isLoaded = true
	return true, nil
end

function ActionRegistry.Get(actionId: string): LoadedActionDefinition?
	return definitionsById[actionId]
end

function ActionRegistry.GetAll(): { LoadedActionDefinition }
	return orderedDefinitions
end

function ActionRegistry.GetAllById(): { [string]: LoadedActionDefinition }
	return definitionsById
end

function ActionRegistry.IsLoaded(): boolean
	return isLoaded
end

function ActionRegistry._resetForTests(): ()
	isLoaded = false
	definitionsById = {}
	orderedDefinitions = {}
	table.freeze(definitionsById)
	table.freeze(orderedDefinitions)
end

return ActionRegistry
