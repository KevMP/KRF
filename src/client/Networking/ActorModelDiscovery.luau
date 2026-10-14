--!strict
local Types = require(script.Parent.ActorStreamTypes)

local ActorModelDiscovery = {} :: Types.DiscoveryModule

function ActorModelDiscovery.new(_root: Instance?): Types.DiscoveryAdapter
	error("N4NotImplemented:ActorModelDiscovery.new")
end

return ActorModelDiscovery
