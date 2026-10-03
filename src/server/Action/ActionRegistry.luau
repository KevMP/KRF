--!strict
local ActionTypes = require(script.Parent.types)
local ActionValidator = require(script.Parent.ActionValidator)
local ActionControllerHooks = require(script.Parent.utils.ActionControllerHooks)

type ActionDefinition = ActionTypes.ActionDefinition
type ActionFactory = ActionTypes.ActionFactory
type ActionRegistry = ActionTypes.ActionRegistry
type LoadedActionDefinition = ActionTypes.LoadedActionDefinition
type PreparedActionCatalog = ActionTypes.PreparedActionCatalog

local ActionRegistry = {} :: ActionRegistry
local isLoaded: boolean = false
local definitionsById: { [string]: LoadedActionDefinition } = {}
local orderedDefinitions: { LoadedActionDefinition } = {}
local factoriesById: { [string]: ActionFactory } = {}

table.freeze(definitionsById)
table.freeze(orderedDefinitions)
table.freeze(factoriesById)

function ActionRegistry.Prepare(
	factories: { ActionFactory },
	preparedTagIds: { [string]: boolean },
	preparedResourceIds: { [string]: boolean }
): (PreparedActionCatalog?, string?)
	if isLoaded then
		return nil, "ActionDefinitionsAlreadyLoaded"
	end
	if type(factories) ~= "table" then
		return nil, "ActionDefinitionsMustBeTable"
	end
	local count: number = 0
	for key in factories do
		if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
			return nil, "ActionDefinitionsMustBeArray"
		end
		count += 1
	end
	local definitions: { ActionDefinition } = {}
	for index: number = 1, count do
		local factory: ActionFactory = factories[index]
		if factory == nil then
			return nil, "ActionDefinitionsMustBeArray"
		end
		if type(factory) ~= "function" then
			return nil, "ActionFactoryMustBeFunction"
		end
		local succeeded: boolean, result: any, _second: any, failureKind: string? =
			ActionControllerHooks.RunNonSuspending(factory)
		if not succeeded then
			return nil, if failureKind == "Yielded" then "ActionFactoryYielded" else "ActionFactoryFailed"
		end
		if result == nil then
			return nil, "ActionDefinitionMissing"
		end
		if type(result) ~= "table" then
			return nil, "ActionDefinitionMustBeTable"
		end
		definitions[index] = result
	end
	local valid: boolean, reason: string? =
		ActionValidator.ValidateCatalog(definitions, preparedTagIds, preparedResourceIds)
	if not valid then
		return nil, reason
	end

	local stagedDefinitionsById: { [string]: LoadedActionDefinition } = {}
	local stagedOrderedDefinitions: { LoadedActionDefinition } = {}
	local stagedFactoriesById: { [string]: ActionFactory } = {}
	for index: number, definition: ActionDefinition in definitions do
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
			onStopRequested = definition.onStopRequested,
			onUpdate = definition.onUpdate,
			onEnd = definition.onEnd,
			onInterrupt = definition.onInterrupt,
			canBeInterruptedBy = definition.canBeInterruptedBy,
		}) :: LoadedActionDefinition
		stagedDefinitionsById[loadedDefinition.id] = loadedDefinition
		stagedFactoriesById[loadedDefinition.id] = factories[index]
		table.insert(stagedOrderedDefinitions, loadedDefinition)
	end
	return {
		definitionsById = table.freeze(stagedDefinitionsById),
		orderedDefinitions = table.freeze(stagedOrderedDefinitions),
		factoriesById = table.freeze(stagedFactoriesById),
	},
		nil
end

function ActionRegistry.Publish(prepared: PreparedActionCatalog): (boolean, string?)
	if isLoaded then
		return false, "ActionDefinitionsAlreadyLoaded"
	end
	definitionsById = prepared.definitionsById
	orderedDefinitions = prepared.orderedDefinitions
	factoriesById = prepared.factoriesById
	isLoaded = true
	return true, nil
end

function ActionRegistry.Load(
	factories: { ActionFactory },
	preparedTagIds: { [string]: boolean },
	preparedResourceIds: { [string]: boolean }
): (boolean, string?)
	local prepared: PreparedActionCatalog?, reason: string? =
		ActionRegistry.Prepare(factories, preparedTagIds, preparedResourceIds)
	if prepared == nil then
		return false, reason
	end
	return ActionRegistry.Publish(prepared)
end

function ActionRegistry.CreateExecution(actionId: string): (ActionDefinition?, string?)
	local factory: ActionFactory? = factoriesById[actionId]
	if factory == nil then
		return nil, "UnknownActionId:" .. actionId
	end
	local succeeded: boolean, result: any, _second: any, failureKind: string?, failureDetail: any =
		ActionControllerHooks.RunNonSuspending(factory)
	if not succeeded then
		warn(
			"[ActionRegistry] factory failed actionId="
				.. actionId
				.. " reason="
				.. tostring(failureDetail or failureKind)
		)
		return nil, if failureKind == "Yielded" then "ActionFactoryYielded" else "ActionFactoryFailed"
	end
	local valid: boolean = ActionValidator.ValidateExecutionDefinition(result, actionId)
	if not valid then
		return nil, "ActionFactoryInvalidResult"
	end
	return result :: ActionDefinition, nil
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
	factoriesById = {}
	table.freeze(definitionsById)
	table.freeze(orderedDefinitions)
	table.freeze(factoriesById)
end

return ActionRegistry
