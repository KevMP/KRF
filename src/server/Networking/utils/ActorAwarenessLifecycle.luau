--!strict
local Types = require(script.Parent.Parent.types)
local ActorTypes = require(script.Parent.Parent.Parent.Actor.types)

local ActorAwarenessLifecycle = {}
local installed: Types.ActorAwarenessRuntime? = nil

function ActorAwarenessLifecycle.Install(runtime: Types.ActorAwarenessRuntime?): ()
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
