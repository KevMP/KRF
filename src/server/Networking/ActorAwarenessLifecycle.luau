--!strict
local Types = require(script.Parent.AwarenessTypes)
local ActorTypes = require(script.Parent.Parent.Actor.types)

local ActorAwarenessLifecycle = {}
local installed: Types.Runtime? = nil

function ActorAwarenessLifecycle.Install(runtime: Types.Runtime?): ()
	installed = runtime
end
function ActorAwarenessLifecycle.Register(actor: ActorTypes.Actor): ()
	if installed ~= nil then
		installed:OnActorRegistered(actor)
	end
end
function ActorAwarenessLifecycle.Unregister(actor: ActorTypes.Actor): ()
	if installed ~= nil then
		installed:OnActorUnregistering(actor)
	end
end

return ActorAwarenessLifecycle
