--!strict
local ReplicationTypes = require(script.Parent.types)

type ReplicationDomainDefinition = ReplicationTypes.ReplicationDomainDefinition
type LoadedReplicationDomainDefinition = ReplicationTypes.LoadedReplicationDomainDefinition
type PreparedReplicationDomainCatalog = ReplicationTypes.PreparedReplicationDomainCatalog

local ReplicationDomainRegistry = {} :: ReplicationTypes.InternalReplicationDomainRegistry
local definitionsById: { [string]: LoadedReplicationDomainDefinition } =
	table.freeze({} :: { [string]: LoadedReplicationDomainDefinition })
local orderedDefinitions: { LoadedReplicationDomainDefinition } =
	table.freeze({} :: { LoadedReplicationDomainDefinition })

function ReplicationDomainRegistry.Prepare(
	_definitions: { ReplicationDomainDefinition }
): (PreparedReplicationDomainCatalog?, string?)
	-- TODO N1: stage the entire domain/event/schema catalog without publication.
	return nil, "ReplicationDomainsNotImplemented"
end

function ReplicationDomainRegistry.Publish(_catalog: PreparedReplicationDomainCatalog): (boolean, string?)
	-- TODO N1: publish once, after Server.Init has prepared every startup catalog.
	return false, "ReplicationDomainsNotImplemented"
end

function ReplicationDomainRegistry.Get(domainId: string): LoadedReplicationDomainDefinition?
	return definitionsById[domainId]
end

function ReplicationDomainRegistry.GetAll(): { LoadedReplicationDomainDefinition }
	return orderedDefinitions
end

function ReplicationDomainRegistry.GetAllById(): { [string]: LoadedReplicationDomainDefinition }
	return definitionsById
end

function ReplicationDomainRegistry.IsLoaded(): boolean
	return false
end

function ReplicationDomainRegistry._resetForTests(): ()
	definitionsById = table.freeze({} :: { [string]: LoadedReplicationDomainDefinition })
	orderedDefinitions = table.freeze({} :: { LoadedReplicationDomainDefinition })
end

return ReplicationDomainRegistry
