--!strict
local ReplicationTypes = require(script.Parent.types)
local TagsReplication = require(script.Parent.Parent.Networking.utils.TagsReplication)

local BuiltInReplicationDomains = {} :: ReplicationTypes.BuiltInReplicationDomainBuilder

function BuiltInReplicationDomains.Build(
	catalogs: ReplicationTypes.ReplicationDomainBuildCatalogs
): ({ ReplicationTypes.ReplicationDomainDefinition }?, string?)
	local tags: ReplicationTypes.ReplicationDomainDefinition? = TagsReplication.Build(catalogs.tags)
	return if tags ~= nil then { tags } else {}, nil
end

return BuiltInReplicationDomains
