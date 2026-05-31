--!strict
local PropertyTypes = require(script.Parent.types)
local ActorTypes = require(script.Parent.Parent.Actor.types)

export type PropertyController = PropertyTypes.PropertyController
type Actor = ActorTypes.Actor

local PropertyController = {}

function PropertyController.new(actor: Actor): PropertyController
	local controller: PropertyController = {} :: PropertyController

	return controller
end

return PropertyController
