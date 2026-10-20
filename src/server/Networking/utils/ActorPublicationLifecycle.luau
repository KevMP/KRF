--!strict
local ActorTypes = require(script.Parent.Parent.Parent.Actor.types)

local Types = require(script.Parent.Parent.types)
local ActorPublicationLifecycle = {}
local installed: Types.PublicationRuntime? = nil

function ActorPublicationLifecycle.Install(runtime: Types.PublicationRuntime?): ()
	installed = runtime
end

function ActorPublicationLifecycle.AttachActor(actor: ActorTypes.Actor): (boolean, string?)
	if installed == nil then
		return true, nil
	end

	return installed:AttachActor(actor)
end

function ActorPublicationLifecycle.DetachActor(actor: ActorTypes.Actor): ()
	if installed ~= nil then
		installed:DetachActor(actor)
	end
end

function ActorPublicationLifecycle.WithActorCommit(actor: ActorTypes.Actor, callback: () -> ()): ()
	if installed ~= nil then
		installed:WithActorCommit(actor, callback)
	else
		callback()
	end
end

return ActorPublicationLifecycle
