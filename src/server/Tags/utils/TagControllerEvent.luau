--!strict
local serverFolder = script.Parent.Parent.Parent
local SignalFolder = serverFolder.Parent.shared.Signal

local ActorTypes = require(serverFolder.Actor.types)
local SignalTypes = require(SignalFolder.types)

export type TagControllerEventContext = {
	actor: ActorTypes.Actor,
	ownedSignals: SignalTypes.OwnedSignals,
	tagAddedSignal: SignalTypes.Signal<ActorTypes.Actor, string>,
	tagRemovedSignal: SignalTypes.Signal<ActorTypes.Actor, string>,
	tagRefreshedSignal: SignalTypes.Signal<ActorTypes.Actor, string>,
	tagChangedSignal: SignalTypes.Signal<ActorTypes.Actor, string>,
	tagExpiredSignal: SignalTypes.Signal<ActorTypes.Actor, string>,
}

local TagControllerEventUtils = {}

function TagControllerEventUtils.FireTagAdded(eventContext: TagControllerEventContext, tagId: string): ()
	eventContext.ownedSignals:WithDeferredDestroy(function()
		eventContext.tagAddedSignal:Fire(eventContext.actor, tagId)
		eventContext.tagChangedSignal:Fire(eventContext.actor, tagId)
	end)
end

function TagControllerEventUtils.FireTagRefreshed(eventContext: TagControllerEventContext, tagId: string): ()
	eventContext.ownedSignals:WithDeferredDestroy(function()
		eventContext.tagRefreshedSignal:Fire(eventContext.actor, tagId)
		eventContext.tagChangedSignal:Fire(eventContext.actor, tagId)
	end)
end

function TagControllerEventUtils.FireTagRemoved(eventContext: TagControllerEventContext, tagId: string): ()
	eventContext.ownedSignals:WithDeferredDestroy(function()
		eventContext.tagRemovedSignal:Fire(eventContext.actor, tagId)
		eventContext.tagChangedSignal:Fire(eventContext.actor, tagId)
	end)
end

function TagControllerEventUtils.FireTagExpired(eventContext: TagControllerEventContext, tagId: string): ()
	eventContext.ownedSignals:WithDeferredDestroy(function()
		eventContext.tagExpiredSignal:Fire(eventContext.actor, tagId)
		eventContext.tagChangedSignal:Fire(eventContext.actor, tagId)
	end)
end

return TagControllerEventUtils
