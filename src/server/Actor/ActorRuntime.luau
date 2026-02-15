--!strict
local SignalFolder = script.Parent.Parent.Parent.shared.Signal

local ActorTypes = require(script.Parent.types)
local SignalTypes = require(SignalFolder.types)

export type Actor = ActorTypes.Actor
export type ActorRuntime = ActorTypes.ActorRuntime
export type RegisterActorOpts = ActorTypes.RegisterActorOpts

local ActorRegistry: ActorTypes.ActorRegistry = require(script.Parent.ActorRegistry)
local ActorEntity = require(script.Parent.ActorEntity)
local SignalModule = require(SignalFolder.SignalModule)

local ActorRuntime = {} :: ActorRuntime

local ActorRegisteredSignal: SignalTypes.Signal<Actor> = SignalModule.new()
local ActorRegisteredEvent: SignalTypes.Event<Actor> = SignalModule.wrapEvent(ActorRegisteredSignal)

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

function ActorRuntime.AttachControllers(_actor: Actor): (boolean, string?)
	return true, nil
end

function ActorRuntime.DetachAllControllers(_actor: Actor): ()
	return
end

ActorRuntime.OnActorRegistered = ActorRegisteredEvent

return ActorRuntime
