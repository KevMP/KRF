--!strict
local SignalFolder = script.Parent.Parent.Parent.shared.Signal

local ActorTypes = require(script.Parent.types)
local SignalTypes = require(SignalFolder.types)
local ControllerTypes = require(script.Parent.Parent.Controller.types)

export type Actor = ActorTypes.Actor
export type ActorRuntime = ActorTypes.ActorRuntime
export type Controller = ActorTypes.Controller
export type RegisterActorOpts = ActorTypes.RegisterActorOpts
export type ControllerDef = ControllerTypes.ControllerDef

local ActorRegistry: ActorTypes.ActorRegistry = require(script.Parent.ActorRegistry)
local ActorEntity = require(script.Parent.ActorEntity)
local SignalModule = require(SignalFolder.SignalModule)
local ControllerRegistry = require(script.Parent.Parent.Controller.ControllerRegistry)

local ActorRuntime = {} :: ActorRuntime

local ActorRegisteredSignal: SignalTypes.Signal<Actor> = SignalModule.new()
local ActorRegisteredEvent: SignalTypes.Event<Actor> = SignalModule.wrapEvent(ActorRegisteredSignal)

local ActorUnregisteringSignal: SignalTypes.Signal<Actor, string?> = SignalModule.new()
local ActorUnregisteringEvent: SignalTypes.Event<Actor, string?> = SignalModule.wrapEvent(ActorUnregisteringSignal)

local ActorUnregisteredSignal: SignalTypes.Signal<Actor, string?> = SignalModule.new()
local ActorUnregisteredEvent: SignalTypes.Event<Actor, string?> = SignalModule.wrapEvent(ActorUnregisteredSignal)

local function DestroyController(controllerKey: string, controller: Controller): ()
	local ok: boolean, err: any = pcall((controller :: any).Destroy, controller, nil)
	if not ok then
		warn("[ActorRuntime] Controller Destroy failed key=", controllerKey, " err=", err)
	end
end

function ActorRuntime.RegisterActor(model: Model, _opts: RegisterActorOpts?): (Actor?, string?)
	local actor: Actor = ActorEntity.new()
	local ok: boolean, reason: string? = ActorRegistry.BindModel(actor, model)

	if ok then
		local attachSuccess: boolean, attachFailReason: string? = ActorRuntime.AttachControllers(actor)

		if not attachSuccess then
			ActorRuntime.DetachAllControllers(actor)
			ActorRegistry.UnbindModel(actor)
			return nil, attachFailReason
		end

		actor.enabled = true
		ActorRegisteredSignal:Fire(actor)
		return actor, nil
	else
		return nil, reason
	end
end

function ActorRuntime.UnregisterActor(actor: Actor, reason: string?): (boolean, string?)
	if actor.enabled == false then
		return false, "AlreadyUnregistered"
	end

	actor.enabled = false
	ActorUnregisteringSignal:Fire(actor, reason)
	ActorRuntime.DetachAllControllers(actor)
	ActorRegistry.UnbindModel(actor)
	ActorUnregisteredSignal:Fire(actor, reason)

	return true, nil
end

function ActorRuntime.AttachControllers(actor: Actor): (boolean, string?)
	local autoAttachKeys: { string } = ControllerRegistry.GetAutoAttachKeys()
	local orderedKeys: { string }?, reason: string? = ControllerRegistry.ResolveOrder(autoAttachKeys)
	local attachedKeysThisCall: { string } = {}
	local returnErrorMessage: string? = nil

	if orderedKeys == nil then
		return false, reason
	end

	for _, controllerKey: string in orderedKeys do
		local controllerDef: ControllerDef? = ControllerRegistry.Get(controllerKey)

		if not controllerDef then
			returnErrorMessage = "UnknownControllerKey:" .. controllerKey
			break
		end

		local factorySuccess: boolean, factoryResult: any = pcall(controllerDef.factory, actor)

		if not factorySuccess then
			warn("[ActorRuntime] Controller factory failed key=", controllerKey, " err=", factoryResult)
			returnErrorMessage = "FactoryError:" .. controllerKey
			break
		end
		local controller: Controller? = factoryResult
		if not controller then
			returnErrorMessage = "FactoryDidNotCreateController:" .. controllerKey
			break
		end

		if typeof((controller :: any).Destroy) ~= "function" then
			returnErrorMessage = "ControllerContractNotObliged:" .. controllerKey
			break
		end

		local attachSuccess: boolean = actor:SetController(controllerKey, controller)
		if not attachSuccess then
			returnErrorMessage = "ControllerAttachmentFailed:" .. controllerKey
			DestroyController(controllerKey, controller)
			break
		end
		table.insert(attachedKeysThisCall, controllerKey)
	end

	if returnErrorMessage then
		for index: number = #attachedKeysThisCall, 1, -1 do
			local controllerKey: string = attachedKeysThisCall[index]
			local removedController: Controller? = actor:RemoveController(controllerKey)
			if removedController then
				DestroyController(controllerKey, removedController)
			end
		end
		return false, returnErrorMessage
	end

	return true, nil
end

function ActorRuntime.DetachAllControllers(actor: Actor): ()
	for _, controllerKey: string in actor:GetControllerKeys() do
		local controller: Controller? = actor:RemoveController(controllerKey)
		if controller then
			DestroyController(controllerKey, controller)
		end
	end
end

ActorRegistry.SetModelGoneHandler(function(actor: Actor, reason: string?)
	-- discard returns; handler is “fire-and-forget”
	ActorRuntime.UnregisterActor(actor, reason)
end)

ActorRuntime.OnActorRegistered = ActorRegisteredEvent
ActorRuntime.OnActorUnregistering = ActorUnregisteringEvent
ActorRuntime.OnActorUnregistered = ActorUnregisteredEvent

return ActorRuntime
