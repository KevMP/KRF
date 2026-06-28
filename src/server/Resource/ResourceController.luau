local serverFolder = script.Parent.Parent
local SignalFolder = serverFolder.Parent.shared.Signal

local ResourceTypes = require(script.Parent.types)
local ActorTypes = require(serverFolder.Actor.types)

type Actor = ActorTypes.Actor
type ResourceController = ResourceTypes.ResourceController

local ResourceController = {}

function ResourceController.new(actor: Actor): ResourceController
	local controller: ResourceController = {}
  

	return controller :: ResourceController
end

return ResourceController
