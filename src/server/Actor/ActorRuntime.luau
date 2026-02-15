--!strict
local SignalFolder = script.Parent.Parent.Parent.shared.Signal

local ActorTypes = require(script.Parent.types)
local SignalTypes = require(SignalFolder.types)

export type Actor = ActorTypes.Actor
export type ActorRuntime = ActorTypes.ActorRuntime
export type Controller = ActorTypes.Controller
export type RegisterActorOpts = ActorTypes.RegisterActorOpts

local ActorRegistry: ActorTypes.ActorRegistry = require(script.Parent.ActorRegistry)
local ActorEntity = require(script.Parent.ActorEntity)
local SignalModule = require(SignalFolder.SignalModule)

local ActorRuntime = {} :: ActorRuntime

local ActorRegisteredSignal: SignalTypes.Signal<Actor> = SignalModule.new()
local ActorRegisteredEvent: SignalTypes.Event<Actor> = SignalModule.wrapEvent(ActorRegisteredSignal)

local ActorUnregisteringSignal: SignalTypes.Signal<Actor, string?> = SignalModule.new()
local ActorUnregisteringEvent: SignalTypes.Event<Actor, string?> = SignalModule.wrapEvent(ActorUnregisteringSignal)

local ActorUnregisteredSignal: SignalTypes.Signal<Actor, string?> = SignalModule.new()
local ActorUnregisteredEvent: SignalTypes.Event<Actor, string?> = SignalModule.wrapEvent(ActorUnregisteredSignal)

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

function ActorRuntime.AttachControllers(_actor: Actor): (boolean, string?)
	return true, nil
end

function ActorRuntime.DetachAllControllers(actor: Actor): ()
	for _, controllerKey: string in actor:GetControllerKeys() do
		local controller: Controller? = actor:RemoveController(controllerKey)
		if controller then
			local ok: boolean, err: any = pcall(function()
				controller:Destroy()
			end, nil)

			if not ok then
				warn("[ActorRuntime] Controller Destroy failed key=", controllerKey, " err=", err)
			end
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
