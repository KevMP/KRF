--!strict
local ActionTypes = require(script.Parent.types)
local ActionValidator = require(script.Parent.ActionValidator)
local ActionControllerHooks = require(script.Parent.utils.ActionControllerHooks)

type ActionDefinition = ActionTypes.ActionDefinition
type ActionFactory = ActionTypes.ActionFactory
type InternalActionImplementation = ActionTypes.InternalActionImplementation
type InternalActionRegistry = ActionTypes.InternalActionRegistry
type LoadedActionDefinition = ActionTypes.LoadedActionDefinition
type PreparedActionCatalog = ActionTypes.PreparedActionCatalog

local ActionRegistry = {} :: InternalActionRegistry
local isLoaded: boolean = false
local definitionsById: { [string]: LoadedActionDefinition } = {}
local orderedDefinitions: { LoadedActionDefinition } = {}
local factoriesById: { [string]: ActionFactory } = {}

local function normalizeRequirements(
	requirements: { [string]: ActionTypes.ActionResourceRequirement }?
): { [string]: ActionTypes.ActionResourceRequirement }
	local owned: { [string]: ActionTypes.ActionResourceRequirement } = {}
	for id: string, requirement: ActionTypes.ActionResourceRequirement in requirements or {} do
		local copy: ActionTypes.ActionResourceRequirement = table.clone(requirement)
		owned[id] = copy
		table.freeze(copy)
	end
	return table.freeze(owned)
end

local function normalizeCosts(
	costs: { [string]: number | ActionTypes.ActionResourceCost }?
): { [string]: number | ActionTypes.ActionResourceCost }
	local owned: { [string]: number | ActionTypes.ActionResourceCost } = {}
	for id: string, cost: number | ActionTypes.ActionResourceCost in costs or {} do
		if type(cost) == "number" then
			owned[id] = cost
		else
			local copy: ActionTypes.ActionResourceCost = table.clone(cost :: ActionTypes.ActionResourceCost)
			owned[id] = copy
			table.freeze(copy)
		end
	end
	return table.freeze(owned)
end

local function normalizeTagApplications(
	applications: { ActionTypes.ActionTagApplication }?
): { ActionTypes.ActionTagApplicationOptions }
	local normalized: { ActionTypes.ActionTagApplicationOptions } = {}
	for _, application: ActionTypes.ActionTagApplication in applications or {} do
		local entry: ActionTypes.ActionTagApplicationOptions
		if type(application) == "string" then
			entry = { id = application :: string }
		else
			local options: ActionTypes.ActionTagApplicationOptions =
				application :: ActionTypes.ActionTagApplicationOptions
			entry = { id = options.id, duration = options.duration }
		end
		table.freeze(entry)
		table.insert(normalized, entry)
	end
	return table.freeze(normalized)
end

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
		local loadedDefinition: LoadedActionDefinition = {
			id = definition.id,
			visibility = definition.visibility,
			autoGrant = if definition.autoGrant ~= nil then definition.autoGrant else false,
			requiredTags = table.clone(definition.requiredTags or {}),
			blockedTags = table.clone(definition.blockedTags or {}),
			activeTags = normalizeTagApplications(definition.activeTags),
			appliedTags = normalizeTagApplications(definition.appliedTags),
			resourceRequirements = normalizeRequirements(definition.resourceRequirements),
			costs = normalizeCosts(definition.costs),
			locks = table.clone(definition.locks or {}),
			interruptibleBy = table.clone(definition.interruptibleBy or {}),
		}
		table.freeze(loadedDefinition.requiredTags)
		table.freeze(loadedDefinition.blockedTags)
		table.freeze(loadedDefinition.locks)
		table.freeze(loadedDefinition.interruptibleBy)
		table.freeze(loadedDefinition)
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

function ActionRegistry.CreateExecution(actionId: string): (InternalActionImplementation?, string?)
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
	local definition: ActionDefinition = result :: ActionDefinition
	local implementation: InternalActionImplementation = table.freeze({
		onCanStart = definition.onCanStart,
		onStart = definition.onStart,
		onStopRequested = definition.onStopRequested,
		onUpdate = definition.onUpdate,
		onEnd = definition.onEnd,
		onInterrupt = definition.onInterrupt,
		canBeInterruptedBy = definition.canBeInterruptedBy,
	}) :: InternalActionImplementation
	return implementation, nil
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
