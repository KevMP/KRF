--!strict
local ActionTypes = require(script.Parent.types)
local ActorTypes = require(script.Parent.Parent.Actor.types)
local SignalTypes = require(script.Parent.Parent.Parent.shared.Signal.types)
local SignalModule = require(script.Parent.Parent.Parent.shared.Signal.SignalModule)
local OwnedSignalsModule = require(script.Parent.Parent.Parent.shared.Signal.OwnedSignals)
local ActionRegistry = require(script.Parent.ActionRegistry)
local ActionControllerHooks = require(script.Parent.utils.ActionControllerHooks)
local ActionControllerGrantsModule = require(script.Parent.utils.ActionControllerGrants)
local ActionControllerInstancesModule = require(script.Parent.utils.ActionControllerInstances)

type Actor = ActorTypes.Actor
type ActionController = ActionTypes.ActionController
type ActionLifecycleEvent = ActionTypes.ActionLifecycleEvent
type ActionInterruptedEvent = ActionTypes.ActionInterruptedEvent
type ActionRequestResult = ActionTypes.ActionRequestResult
type LoadedActionDefinition = ActionTypes.LoadedActionDefinition
type ActionControllerGrants = ActionControllerGrantsModule.ActionControllerGrants
type ActionControllerInstances = ActionControllerInstancesModule.ActionControllerInstances

local ActionControllerModule = {}

function ActionControllerModule.new(actor: Actor): ActionController
	assert(ActionRegistry.IsLoaded(), "ActionRegistryNotLoaded")

	local catalog: { LoadedActionDefinition } = ActionRegistry.GetAll()
	local grantChangedSignal: SignalTypes.Signal<Actor, string, boolean> = SignalModule.new()
	local startedSignal: SignalTypes.Signal<ActionLifecycleEvent> = SignalModule.new()
	local endedSignal: SignalTypes.Signal<ActionLifecycleEvent> = SignalModule.new()
	local interruptedSignal: SignalTypes.Signal<ActionInterruptedEvent> = SignalModule.new()
	local ownedSignals: SignalTypes.OwnedSignals =
		OwnedSignalsModule.new({ grantChangedSignal, startedSignal, endedSignal, interruptedSignal })
	local controllerState: { destroyed: boolean } = { destroyed = false }
	local grants: ActionControllerGrants =
		ActionControllerGrantsModule.new(actor, catalog, ownedSignals, grantChangedSignal, controllerState)
	local instances: ActionControllerInstances = ActionControllerInstancesModule.new(
		actor,
		ownedSignals,
		startedSignal,
		endedSignal,
		interruptedSignal,
		controllerState
	)
	local controller: ActionController = {} :: ActionController

	function controller:SetGrants(sourceId: string, actionIds: { string }): (boolean, string?)
		return grants:SetGrants(sourceId, actionIds)
	end

	function controller:IsActionGranted(actionId: string): boolean
		return grants:IsGranted(actionId)
	end

	function controller:GetGrantedActions(): { string }
		return grants:GetGrantedActions()
	end

	function controller:RequestAction(actionId: string, parameters: any?): ActionRequestResult
		if controllerState.destroyed then
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
		if not grants:IsGranted(actionId) then
			return { accepted = false, reason = "ActionNotGranted" }
		end

		local callback = definition.onCanStart
		if callback ~= nil then
			local startContext = table.freeze({ actor = actor, actionId = actionId, parameters = parameters })
			local succeeded: boolean, allowed: any, customReason: any, failureKind: string?, failureDetail: any =
				ActionControllerHooks.RunNonSuspending(callback, startContext)
			if not succeeded then
				ActionControllerHooks.WarnFailure(actor, actionId, "onCanStart", failureDetail or failureKind)
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

		if controllerState.destroyed then
			return { accepted = false, reason = "ActionControllerDestroyed" }
		end
		if not actor.enabled then
			return { accepted = false, reason = "ActorDisabled" }
		end
		if not grants:IsGranted(actionId) then
			return { accepted = false, reason = "ActionNotGranted" }
		end

		local sequenceId: number = instances:Start(actionId, definition, parameters)
		return { accepted = true, sequenceId = sequenceId }
	end

	function controller:RequestStop(sequenceId: number, parameters: any?): (boolean, string?)
		return instances:RequestStop(sequenceId, parameters)
	end

	function controller:EndAction(sequenceId: number): (boolean, string?)
		return instances:EndAction(sequenceId)
	end

	function controller:InterruptAction(sequenceId: number, reason: string): (boolean, string?)
		return instances:InterruptAction(sequenceId, reason)
	end

	function controller:Destroy(): ()
		if controllerState.destroyed then
			return
		end
		controllerState.destroyed = true
		instances:Destroy()
		grants:Destroy()
		ownedSignals:Destroy()
	end

	controller.OnActionGrantChanged = SignalModule.wrapEvent(grantChangedSignal)
	controller.OnActionStarted = SignalModule.wrapEvent(startedSignal)
	controller.OnActionEnded = SignalModule.wrapEvent(endedSignal)
	controller.OnActionInterrupted = SignalModule.wrapEvent(interruptedSignal)
	return controller
end

return ActionControllerModule
