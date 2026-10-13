--!strict
local ActorTypes = require(script.Parent.Parent.Actor.types)

-- Planned synchronous seam: ActorRuntime calls AttachActor after controllers
-- attach and before enabling; DetachActor runs before controller destruction.
-- No public Actor signal semantics or existing runtime wiring is changed yet.
local ActorPublicationLifecycle = {}

function ActorPublicationLifecycle.AttachActor(_actor: ActorTypes.Actor): (boolean, string?)
	error("N3NotImplemented", 2)
end

function ActorPublicationLifecycle.DetachActor(_actor: ActorTypes.Actor): ()
	error("N3NotImplemented", 2)
end

return ActorPublicationLifecycle
