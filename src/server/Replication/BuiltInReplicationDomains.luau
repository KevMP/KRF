--!strict
local ReplicationTypes = require(script.Parent.types)

local BuiltInReplicationDomains = {} :: ReplicationTypes.BuiltInReplicationDomainBuilder

function BuiltInReplicationDomains.Build(
	_catalogs: ReplicationTypes.ReplicationDomainBuildCatalogs
): ({ ReplicationTypes.ReplicationDomainDefinition }?, string?)
	-- N6-N8 select ClientVisible entries from these staged catalogs and construct
	-- KRF.Tags/Resources/Actions definitions here. No registry reads or publication.
	-- All generated definitions join game domains before one validation transaction.
	return {}, nil
end

return BuiltInReplicationDomains
