--!strict
local serverFolder = script.Parent.Parent.Parent
local SignalFolder = serverFolder.Parent.shared.Signal

local ActorTypes = require(serverFolder.Actor.types)
local SignalTypes = require(SignalFolder.types)

export type TagControllerEventContext = {
	actor: ActorTypes.Actor,
	tagAddedSignal: SignalTypes.Signal<ActorTypes.Actor, string>,
	tagRemovedSignal: SignalTypes.Signal<ActorTypes.Actor, string>,
	tagRefreshedSignal: SignalTypes.Signal<ActorTypes.Actor, string>,
	tagChangedSignal: SignalTypes.Signal<ActorTypes.Actor, string>,
}

local TagControllerEventUtils = {}

function TagControllerEventUtils.FireTagAdded(self: TagControllerEventContext, tagId: string): ()
	self.tagAddedSignal:Fire(self.actor, tagId)
	self.tagChangedSignal:Fire(self.actor, tagId)
end

function TagControllerEventUtils.FireTagRefreshed(self: TagControllerEventContext, tagId: string): ()
	self.tagRefreshedSignal:Fire(self.actor, tagId)
	self.tagChangedSignal:Fire(self.actor, tagId)
end

function TagControllerEventUtils.FireTagRemoved(self: TagControllerEventContext, tagId: string): ()
	self.tagRemovedSignal:Fire(self.actor, tagId)
	self.tagChangedSignal:Fire(self.actor, tagId)
end

return TagControllerEventUtils
