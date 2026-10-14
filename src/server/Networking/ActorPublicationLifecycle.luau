--!strict
local ActorTypes = require(script.Parent.Parent.Actor.types)

local PublicationTypes = require(script.Parent.PublicationTypes)
local ActorPublicationLifecycle = {}
local installed: PublicationTypes.Runtime? = nil

function ActorPublicationLifecycle.Install(runtime: PublicationTypes.Runtime?): ()
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

return ActorPublicationLifecycle
