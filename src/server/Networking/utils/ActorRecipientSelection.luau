--!strict
local Types = require(script.Parent.Parent.types)
local ActorTypes = require(script.Parent.Parent.Parent.Actor.types)

local ActorRecipientSelection = {} :: Types.ActorRecipientSelectionModule

-- Select every Ready recipient. ActorAwarenessRuntime owns readiness and stream lifecycle.
function ActorRecipientSelection.ShouldBeAware(_player: Player, _actor: ActorTypes.Actor): boolean
	return true
end

return ActorRecipientSelection
