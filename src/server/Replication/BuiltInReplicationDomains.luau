--!strict
local ReplicationTypes = require(script.Parent.types)
local TagsReplication = require(script.Parent.Parent.Networking.utils.TagsReplication)
local ResourcesReplication = require(script.Parent.Parent.Networking.utils.ResourcesReplication)

local BuiltInReplicationDomains = {} :: ReplicationTypes.BuiltInReplicationDomainBuilder

function BuiltInReplicationDomains.Build(
	catalogs: ReplicationTypes.ReplicationDomainBuildCatalogs
): ({ ReplicationTypes.ReplicationDomainDefinition }?, string?)
	local tags: ReplicationTypes.ReplicationDomainDefinition? = TagsReplication.Build(catalogs.tags)
	local resources: ReplicationTypes.ReplicationDomainDefinition? = ResourcesReplication.Build(catalogs.resources)
	local domains: { ReplicationTypes.ReplicationDomainDefinition } = {}

	if tags ~= nil then
		table.insert(domains, tags)
	end

	if resources ~= nil then
		table.insert(domains, resources)
	end

	return domains, nil
end

return BuiltInReplicationDomains
