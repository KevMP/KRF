--!strict
local ActionTypes = require(script.Parent.types)
local ActorTypes = require(script.Parent.Parent.Actor.types)
local SignalTypes = require(script.Parent.Parent.Parent.shared.Signal.types)
local SignalModule = require(script.Parent.Parent.Parent.shared.Signal.SignalModule)
local OwnedSignalsModule = require(script.Parent.Parent.Parent.shared.Signal.OwnedSignals)
local ActionRegistry = require(script.Parent.ActionRegistry)

type Actor = ActorTypes.Actor
type ActionController = ActionTypes.ActionController
type ActionExecutionContext = ActionTypes.ActionExecutionContext
type ActionLifecycleEvent = ActionTypes.ActionLifecycleEvent
type ActionInterruptedEvent = ActionTypes.ActionInterruptedEvent
type ActionRequestResult = ActionTypes.ActionRequestResult
type ActionStopRequest = ActionTypes.ActionStopRequest
type LoadedActionDefinition = ActionTypes.LoadedActionDefinition
type GrantSet = { [string]: boolean }
type GrantTransition = { actionId: string, isGranted: boolean }
type InternalActionInstance = {
	sequenceId: number,
	identity: {},
	actionId: string,
	definition: LoadedActionDefinition,
	context: ActionExecutionContext,
	stopSignal: SignalTypes.Signal<ActionStopRequest>,
	onStartThread: thread?,
}

local function cancelSuspendedThread(threadToCancel: thread): ()
	if coroutine.status(threadToCancel) ~= "suspended" then
		return
	end
	local cancelled: boolean = pcall(task.cancel, threadToCancel)
	if not cancelled and coroutine.status(threadToCancel) == "suspended" then
		pcall(coroutine.close, threadToCancel)
	end
end

local function runNonSuspending(callback: (...any) -> ...any, ...: any): (boolean, any, any, string?, any)
	local callbackThread: thread = coroutine.create(callback)
	local resumed: boolean, first: any, second: any = coroutine.resume(callbackThread, ...)
	if not resumed then
		return false, nil, nil, "Error", first
	end
	if coroutine.status(callbackThread) ~= "dead" then
		cancelSuspendedThread(callbackThread)
		return false, nil, nil, "Yielded", nil
	end
	return true, first, second, nil, nil
end

local function validSequenceId(sequenceId: any): boolean
	return type(sequenceId) == "number" and math.isfinite(sequenceId) and sequenceId >= 1 and sequenceId % 1 == 0
end

local ActionControllerModule = {}

function ActionControllerModule.new(actor: Actor): ActionController
	assert(ActionRegistry.IsLoaded(), "ActionRegistryNotLoaded")

	local catalog: { LoadedActionDefinition } = ActionRegistry.GetAll()
	local explicitBySourceId: { [string]: GrantSet } = {}
	local explicitGrantCountById: { [string]: number } = {}
	local autoGrantedById: GrantSet = {}
	local effectiveById: GrantSet = {}
	local emptyGrantedActionIds: { string } = {}
	table.freeze(emptyGrantedActionIds)
	local grantedActionIds: { string } = emptyGrantedActionIds
	local grantSnapshotDirty: boolean = true
	for _, definition: LoadedActionDefinition in catalog do
		if definition.autoGrant then
			autoGrantedById[definition.id] = true
			effectiveById[definition.id] = true
		end
	end

	local grantChangedSignal: SignalTypes.Signal<Actor, string, boolean> = SignalModule.new()
	local startedSignal: SignalTypes.Signal<ActionLifecycleEvent> = SignalModule.new()
	local endedSignal: SignalTypes.Signal<ActionLifecycleEvent> = SignalModule.new()
	local interruptedSignal: SignalTypes.Signal<ActionInterruptedEvent> = SignalModule.new()
	local ownedSignals: SignalTypes.OwnedSignals =
		OwnedSignalsModule.new({ grantChangedSignal, startedSignal, endedSignal, interruptedSignal })
	local destroyed: boolean = false
	local controller: ActionController = {} :: ActionController
	local nextSequenceId: number = 1
	local activeBySequenceId: { [number]: InternalActionInstance } = {}

	local function isActive(instance: InternalActionInstance): boolean
		return activeBySequenceId[instance.sequenceId] == instance
	end

	local function warnHookFailure(instance: InternalActionInstance, hookName: string, detail: any): ()
		warn(
			"[ActionController] "
				.. hookName
				.. " failed actorId="
				.. actor:GetId()
				.. " actionId="
				.. instance.actionId
				.. " reason="
				.. tostring(detail)
		)
	end

	local function retireStart(instance: InternalActionInstance): ()
		local startThread: thread? = instance.onStartThread
		if startThread == nil then
			return
		end
		if coroutine.running() ~= startThread then
			cancelSuspendedThread(startThread)
			instance.onStartThread = nil
		end
	end

	local function commitEnd(instance: InternalActionInstance): boolean
		if not isActive(instance) then
			return false
		end
		activeBySequenceId[instance.sequenceId] = nil
		retireStart(instance)
		instance.stopSignal:Destroy()
		return true
	end

	local function commitInterrupt(instance: InternalActionInstance): boolean
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
					runNonSuspending(callback, instance.context)
				if not succeeded then
					warnHookFailure(instance, "onEnd", failureDetail or failureKind)
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
					runNonSuspending(callback, instance.context, reason)
				if not succeeded then
					warnHookFailure(instance, "onInterrupt", failureDetail or failureKind)
				end
			end
		end)
	end

	local function endById(sequenceId: number): (boolean, string?)
		if destroyed then
			return false, "ActionControllerDestroyed"
		end
		if not validSequenceId(sequenceId) then
			return false, "ActionSequenceIdInvalid"
		end
		local instance: InternalActionInstance? = activeBySequenceId[sequenceId]
		if instance == nil then
			return false, "ActionInstanceNotActive"
		end
		commitEnd(instance)
		dispatchEnd(instance)
		return true, nil
	end

	local function interruptById(sequenceId: number, reason: string): (boolean, string?)
		if destroyed then
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
		commitInterrupt(instance)
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
				warnHookFailure(instance, "onStart", failure)
				if commitInterrupt(instance) then
					dispatchInterrupt(instance, "ActionStartFailed")
				end
			end
		end)
		instance.onStartThread = startThread
		local resumed: boolean, failure: any = coroutine.resume(startThread)
		if not resumed then
			instance.onStartThread = nil
			warnHookFailure(instance, "onStart", failure)
			if commitInterrupt(instance) then
				dispatchInterrupt(instance, "ActionStartFailed")
			end
		elseif coroutine.status(startThread) ~= "dead" and not isActive(instance) then
			cancelSuspendedThread(startThread)
			instance.onStartThread = nil
		end
	end

	function controller:SetGrants(sourceId: string, actionIds: { string }): (boolean, string?)
		if destroyed then
			return false, "ActionControllerDestroyed"
		end
		if type(sourceId) ~= "string" then
			return false, "ActionGrantSourceIdMustBeString"
		end
		if sourceId == "" then
			return false, "ActionGrantSourceIdCannotBeEmpty"
		end
		if type(actionIds) ~= "table" then
			return false, "ActionGrantIdsMustBeTable"
		end

		local rawActionIds: any = actionIds
		local count: number = 0
		for key: number in rawActionIds do
			if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
				return false, "ActionGrantIdsMustBeArray"
			end
			count += 1
		end

		local replacement: GrantSet = {}
		for index: number = 1, count do
			local actionId: any = rawActionIds[index]
			if actionId == nil then
				return false, "ActionGrantIdsMustBeArray"
			end
			if type(actionId) ~= "string" then
				return false, "ActionGrantIdMustBeString"
			end
			if actionId == "" then
				return false, "ActionGrantIdCannotBeEmpty"
			end
			if ActionRegistry.Get(actionId) == nil then
				return false, "UnknownActionId:" .. actionId
			end
			replacement[actionId] = true
		end

		local previous: GrantSet = explicitBySourceId[sourceId] or {}
		local nextCountsById: { [string]: number } = {}
		for actionId: string in previous do
			if not replacement[actionId] then
				nextCountsById[actionId] = (explicitGrantCountById[actionId] or 0) - 1
			end
		end
		for actionId: string in replacement do
			if not previous[actionId] then
				nextCountsById[actionId] = (explicitGrantCountById[actionId] or 0) + 1
			end
		end
		if next(nextCountsById) == nil then
			return true, nil
		end

		local transitions: { GrantTransition } = {}
		for actionId: string, nextCount: number in nextCountsById do
			local isGranted: boolean = autoGrantedById[actionId] == true or nextCount > 0
			if (effectiveById[actionId] == true) ~= isGranted then
				table.insert(transitions, { actionId = actionId, isGranted = isGranted })
			end
		end

		if next(replacement) == nil then
			explicitBySourceId[sourceId] = nil
		else
			explicitBySourceId[sourceId] = replacement
		end
		for actionId: string, nextCount: number in nextCountsById do
			if nextCount == 0 then
				explicitGrantCountById[actionId] = nil
			else
				explicitGrantCountById[actionId] = nextCount
			end
		end
		for _, transition: GrantTransition in transitions do
			if transition.isGranted then
				effectiveById[transition.actionId] = true
			else
				effectiveById[transition.actionId] = nil
			end
		end
		if #transitions > 0 then
			grantSnapshotDirty = true
			ownedSignals:WithDeferredDestroy(function()
				for _, transition: GrantTransition in transitions do
					grantChangedSignal:Fire(actor, transition.actionId, transition.isGranted)
				end
			end)
		end

		return true, nil
	end

	function controller:IsActionGranted(actionId: string): boolean
		return effectiveById[actionId] == true
	end

	function controller:GetGrantedActions(): { string }
		if grantSnapshotDirty then
			local snapshot: { string } = {}
			for _, definition: LoadedActionDefinition in catalog do
				if effectiveById[definition.id] then
					table.insert(snapshot, definition.id)
				end
			end
			grantedActionIds = table.freeze(snapshot)
			grantSnapshotDirty = false
		end
		return grantedActionIds
	end

	function controller:RequestAction(actionId: string, parameters: any?): ActionRequestResult
		if destroyed then
			return { accepted = false, reason = "ActionControllerDestroyed" }
		end
		if not actor.enabled then
			return { accepted = false, reason = "ActorDisabled" }
		end
		if type(actionId) ~= "string" then
			return { accepted = false, reason = "ActionIdMustBeString" }
		end
		if actionId == "" then
			return { accepted = false, reason = "ActionIdCannotBeEmpty" }
		end
		local definition: LoadedActionDefinition? = ActionRegistry.Get(actionId)
		if definition == nil then
			return { accepted = false, reason = "UnknownActionId:" .. actionId }
		end
		if not effectiveById[actionId] then
			return { accepted = false, reason = "ActionNotGranted" }
		end

		local callback = definition.onCanStart
		if callback ~= nil then
			local startContext = table.freeze({ actor = actor, actionId = actionId, parameters = parameters })
			local succeeded: boolean, allowed: any, customReason: any, failureKind: string?, failureDetail: any =
				runNonSuspending(callback, startContext)
			if not succeeded then
				warn(
					"[ActionController] onCanStart failed actorId="
						.. actor:GetId()
						.. " actionId="
						.. actionId
						.. " reason="
						.. tostring(failureDetail or failureKind)
				)
				return {
					accepted = false,
					reason = if failureKind == "Yielded" then "ActionCanStartYielded" else "ActionCanStartFailed",
				}
			end
			if type(allowed) ~= "boolean" then
				warn(
					"[ActionController] onCanStart invalid result actorId=" .. actor:GetId() .. " actionId=" .. actionId
				)
				return { accepted = false, reason = "ActionCanStartInvalidResult" }
			end
			if not allowed then
				return {
					accepted = false,
					reason = if type(customReason) == "string" and customReason ~= ""
						then customReason
						else "ActionCanStartRejected",
				}
			end
		end

		if destroyed then
			return { accepted = false, reason = "ActionControllerDestroyed" }
		end
		if not actor.enabled then
			return { accepted = false, reason = "ActorDisabled" }
		end
		if not effectiveById[actionId] then
			return { accepted = false, reason = "ActionNotGranted" }
		end

		local instance: InternalActionInstance = commitActivation(actionId, definition, parameters)
		ownedSignals:WithDeferredDestroy(function()
			startedSignal:Fire(lifecycleEvent(instance))
			beginStart(instance)
		end)
		return { accepted = true, sequenceId = instance.sequenceId }
	end

	function controller:RequestStop(sequenceId: number, parameters: any?): (boolean, string?)
		if destroyed then
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

	function controller:EndAction(sequenceId: number): (boolean, string?)
		return endById(sequenceId)
	end

	function controller:InterruptAction(sequenceId: number, reason: string): (boolean, string?)
		return interruptById(sequenceId, reason)
	end

	function controller:Destroy(): ()
		if destroyed then
			return
		end
		destroyed = true
		local activeInstances: { InternalActionInstance } = {}
		for _, instance: InternalActionInstance in activeBySequenceId do
			table.insert(activeInstances, instance)
		end
		table.sort(activeInstances, function(left: InternalActionInstance, right: InternalActionInstance): boolean
			return left.sequenceId < right.sequenceId
		end)
		for _, instance: InternalActionInstance in activeInstances do
			commitInterrupt(instance)
		end
		for _, instance: InternalActionInstance in activeInstances do
			dispatchInterrupt(instance, "ActionControllerDestroyed")
		end
		table.clear(explicitBySourceId)
		table.clear(explicitGrantCountById)
		table.clear(autoGrantedById)
		table.clear(effectiveById)
		grantedActionIds = emptyGrantedActionIds
		grantSnapshotDirty = false
		ownedSignals:Destroy()
	end

	controller.OnActionGrantChanged = SignalModule.wrapEvent(grantChangedSignal)
	controller.OnActionStarted = SignalModule.wrapEvent(startedSignal)
	controller.OnActionEnded = SignalModule.wrapEvent(endedSignal)
	controller.OnActionInterrupted = SignalModule.wrapEvent(interruptedSignal)
	return controller
end

return ActionControllerModule
