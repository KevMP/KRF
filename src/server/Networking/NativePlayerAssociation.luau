--!strict
local Types = require(script.Parent.AwarenessTypes)

local NativePlayerAssociation = {} :: Types.AssociationModule

function NativePlayerAssociation.new(_players: Players?): Types.AssociationSource
	error("N4NotImplemented:NativePlayerAssociation.new")
end

return NativePlayerAssociation
