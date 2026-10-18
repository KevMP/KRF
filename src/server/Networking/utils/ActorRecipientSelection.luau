--!strict
local Types = require(script.Parent.Parent.types)
local ActorTypes = require(script.Parent.Parent.Parent.Actor.types)

local ActorRecipientSelection = {} :: Types.ActorRecipientSelectionModule

-- M0 selects every Ready recipient. Readiness and stream lifecycle remain N4-owned.
function ActorRecipientSelection.ShouldBeAware(_player: Player, _actor: ActorTypes.Actor): boolean
	return true
end

return ActorRecipientSelection
