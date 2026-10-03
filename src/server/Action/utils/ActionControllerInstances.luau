--!strict
local ActionTypes = require(script.Parent.Parent.types)
local ActorTypes = require(script.Parent.Parent.Parent.Actor.types)
local SignalTypes = require(script.Parent.Parent.Parent.Parent.shared.Signal.types)
local SignalModule = require(script.Parent.Parent.Parent.Parent.shared.Signal.SignalModule)
local ActionControllerHooks = require(script.Parent.ActionControllerHooks)

type Actor = ActorTypes.Actor
type ActionExecutionContext = ActionTypes.ActionExecutionContext
type ActionLifecycleEvent = ActionTypes.ActionLifecycleEvent
type ActionInterruptedEvent = ActionTypes.ActionInterruptedEvent
type ActionStopRequest = ActionTypes.ActionStopRequest
type LoadedActionDefinition = ActionTypes.LoadedActionDefinition
type InternalActionInstance = {
	sequenceId: number,
	identity: {},
	actionId: string,
	definition: LoadedActionDefinition,
	context: ActionExecutionContext,
	stopSignal: SignalTypes.Signal<ActionStopRequest>,
	onStartThread: thread?,
}

export type ActionControllerInstances = {
	Start: (
		self: ActionControllerInstances,
		actionId: string,
		definition: LoadedActionDefinition,
		parameters: any?
	) -> number,
	RequestStop: (self: ActionControllerInstances, sequenceId: number, parameters: any?) -> (boolean, string?),
	EndAction: (self: ActionControllerInstances, sequenceId: number) -> (boolean, string?),
	InterruptAction: (self: ActionControllerInstances, sequenceId: number, reason: string) -> (boolean, string?),
	Destroy: (self: ActionControllerInstances) -> (),
}

local ActionControllerInstancesModule = {}

local function validSequenceId(sequenceId: any): boolean
	return type(sequenceId) == "number" and math.isfinite(sequenceId) and sequenceId >= 1 and sequenceId % 1 == 0
end

function ActionControllerInstancesModule.new(
	actor: Actor,
	ownedSignals: SignalTypes.OwnedSignals,
	startedSignal: SignalTypes.Signal<ActionLifecycleEvent>,
	endedSignal: SignalTypes.Signal<ActionLifecycleEvent>,
	interruptedSignal: SignalTypes.Signal<ActionInterruptedEvent>,
	controllerState: { destroyed: boolean }
): ActionControllerInstances
	local instances: ActionControllerInstances = {} :: ActionControllerInstances
	local nextSequenceId: number = 1
	local activeBySequenceId: { [number]: InternalActionInstance } = {}

	local function isActive(instance: InternalActionInstance): boolean
		return activeBySequenceId[instance.sequenceId] == instance
	end

	local function retireStart(instance: InternalActionInstance): ()
		local startThread: thread? = instance.onStartThread
		if startThread == nil then
			return
		end
		if coroutine.running() ~= startThread then
			ActionControllerHooks.CancelSuspendedThread(startThread)
			instance.onStartThread = nil
		end
	end

	local function commitTerminal(instance: InternalActionInstance): boolean
		if not isActive(instance) then
			return false
		end
		activeBySequenceId[instance.sequenceId] = nil
		retireStart(instance)
		instance.stopSignal:Destroy()
		return true
	end

	local function lifecycleEvent(instance: InternalActionInstance): ActionLifecycleEvent
		return {
			actor = actor,
			actionId = instance.actionId,
			sequenceId = instance.sequenceId,
		}
	end

	local function dispatchEnd(instance: InternalActionInstance): ()
		ownedSignals:WithDeferredDestroy(function()
			endedSignal:Fire(lifecycleEvent(instance))
			local callback = instance.definition.onEnd
			if callback ~= nil then
				local succeeded: boolean, _first: any, _second: any, failureKind: string?, failureDetail: any =
					ActionControllerHooks.RunNonSuspending(callback, instance.context)
				if not succeeded then
					ActionControllerHooks.WarnFailure(actor, instance.actionId, "onEnd", failureDetail or failureKind)
				end
			end
		end)
	end

	local function dispatchInterrupt(instance: InternalActionInstance, reason: string): ()
		ownedSignals:WithDeferredDestroy(function()
			interruptedSignal:Fire({
				actor = actor,
				actionId = instance.actionId,
				sequenceId = instance.sequenceId,
				reason = reason,
			})
			local callback = instance.definition.onInterrupt
			if callback ~= nil then
				local succeeded: boolean, _first: any, _second: any, failureKind: string?, failureDetail: any =
					ActionControllerHooks.RunNonSuspending(callback, instance.context, reason)
				if not succeeded then
					ActionControllerHooks.WarnFailure(
						actor,
						instance.actionId,
						"onInterrupt",
						failureDetail or failureKind
					)
				end
			end
		end)
	end

	local function endById(sequenceId: number): (boolean, string?)
		if controllerState.destroyed then
			return false, "ActionControllerDestroyed"
		end
		if not validSequenceId(sequenceId) then
			return false, "ActionSequenceIdInvalid"
		end
		local instance: InternalActionInstance? = activeBySequenceId[sequenceId]
		if instance == nil then
			return false, "ActionInstanceNotActive"
		end
		commitTerminal(instance)
		dispatchEnd(instance)
		return true, nil
	end

	local function interruptById(sequenceId: number, reason: string): (boolean, string?)
		if controllerState.destroyed then
			return false, "ActionControllerDestroyed"
		end
		if not validSequenceId(sequenceId) then
			return false, "ActionSequenceIdInvalid"
		end
		if type(reason) ~= "string" or reason == "" then
			return false, "ActionInterruptReasonInvalid"
		end
		local instance: InternalActionInstance? = activeBySequenceId[sequenceId]
		if instance == nil then
			return false, "ActionInstanceNotActive"
		end
		commitTerminal(instance)
		dispatchInterrupt(instance, reason)
		return true, nil
	end

	local function commitActivation(
		actionId: string,
		definition: LoadedActionDefinition,
		parameters: any?
	): InternalActionInstance
		local sequenceId: number = nextSequenceId
		nextSequenceId += 1
		local identity: {} = {}
		local stopSignal: SignalTypes.Signal<ActionStopRequest> = SignalModule.new()
		local instance: InternalActionInstance = {} :: InternalActionInstance
		local context: ActionExecutionContext = {
			actor = actor,
			actionId = actionId,
			sequenceId = sequenceId,
			parameters = parameters,
			state = {},
			OnStopRequested = SignalModule.wrapEvent(stopSignal),
			IsActive = function(_self: ActionExecutionContext): boolean
				local active: InternalActionInstance? = activeBySequenceId[sequenceId]
				return active ~= nil and active.identity == identity
			end,
			End = function(_self: ActionExecutionContext): (boolean, string?)
				return endById(sequenceId)
			end,
			Interrupt = function(_self: ActionExecutionContext, reason: string): (boolean, string?)
				return interruptById(sequenceId, reason)
			end,
		}
		table.freeze(context)
		instance.sequenceId = sequenceId
		instance.identity = identity
		instance.actionId = actionId
		instance.definition = definition
		instance.context = context
		instance.stopSignal = stopSignal
		instance.onStartThread = nil
		activeBySequenceId[sequenceId] = instance
		return instance
	end

	local function beginStart(instance: InternalActionInstance): ()
		local callback = instance.definition.onStart
		if callback == nil or not isActive(instance) then
			return
		end
		local startThread: thread = coroutine.create(function()
			local succeeded: boolean, failure: any = pcall(callback, instance.context)
			instance.onStartThread = nil
			if not succeeded then
				ActionControllerHooks.WarnFailure(actor, instance.actionId, "onStart", failure)
				if commitTerminal(instance) then
					dispatchInterrupt(instance, "ActionStartFailed")
				end
			end
		end)
		instance.onStartThread = startThread
		local resumed: boolean, failure: any = coroutine.resume(startThread)
		if not resumed then
			instance.onStartThread = nil
			ActionControllerHooks.WarnFailure(actor, instance.actionId, "onStart", failure)
			if commitTerminal(instance) then
				dispatchInterrupt(instance, "ActionStartFailed")
			end
		elseif coroutine.status(startThread) ~= "dead" and not isActive(instance) then
			ActionControllerHooks.CancelSuspendedThread(startThread)
			instance.onStartThread = nil
		end
	end

	function instances:Start(actionId: string, definition: LoadedActionDefinition, parameters: any?): number
		local instance: InternalActionInstance = commitActivation(actionId, definition, parameters)
		ownedSignals:WithDeferredDestroy(function()
			startedSignal:Fire(lifecycleEvent(instance))
			beginStart(instance)
		end)
		return instance.sequenceId
	end

	function instances:RequestStop(sequenceId: number, parameters: any?): (boolean, string?)
		if controllerState.destroyed then
			return false, "ActionControllerDestroyed"
		end
		if not validSequenceId(sequenceId) then
			return false, "ActionSequenceIdInvalid"
		end
		local instance: InternalActionInstance? = activeBySequenceId[sequenceId]
		if instance == nil then
			return false, "ActionInstanceNotActive"
		end
		instance.stopSignal:Fire({ parameters = parameters })
		return true, nil
	end

	function instances:EndAction(sequenceId: number): (boolean, string?)
		return endById(sequenceId)
	end

	function instances:InterruptAction(sequenceId: number, reason: string): (boolean, string?)
		return interruptById(sequenceId, reason)
	end

	function instances:Destroy(): ()
		local activeInstances: { InternalActionInstance } = {}
		for _, instance: InternalActionInstance in activeBySequenceId do
			table.insert(activeInstances, instance)
		end
		table.sort(activeInstances, function(left: InternalActionInstance, right: InternalActionInstance): boolean
			return left.sequenceId < right.sequenceId
		end)
		for _, instance: InternalActionInstance in activeInstances do
			commitTerminal(instance)
		end
		for _, instance: InternalActionInstance in activeInstances do
			dispatchInterrupt(instance, "ActionControllerDestroyed")
		end
	end

	return instances
end

return ActionControllerInstancesModule
