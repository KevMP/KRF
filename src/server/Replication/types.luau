--!strict
local ActorTypes = require(script.Parent.Parent.Actor.types)
local SharedNetworkingTypes = require(script.Parent.Parent.Parent.shared.Networking.types)
local TagTypes = require(script.Parent.Parent.Tags.types)
local ResourceTypes = require(script.Parent.Parent.Resource.types)
local ActionTypes = require(script.Parent.Parent.Action.types)

local types = {}

export type ReplicationAudience = "All" | "Owner"
export type ReplicationEventDefinition = { id: string, payload: SharedNetworkingTypes.SchemaDefinition }
export type ReplicationDomainEvent = { id: string, payload: any }
export type ReplicationDomainOnCommitted = (events: { ReplicationDomainEvent }?) -> ()

export type ReplicationDomainDefinition = {
	id: string,
	state: SharedNetworkingTypes.SchemaDefinition,
	events: { ReplicationEventDefinition }?,
	audience: ReplicationAudience?,
	-- Complete recoverable current truth. Actor-only, synchronous, and non-yielding.
	snapshot: (actor: ActorTypes.Actor) -> any,
	-- Networking attaches this adapter later. Call onCommitted synchronously after
	-- authority commits and before consumer callbacks; events preserve occurrence order.
	-- Capture/validate event payloads before returning. No historical event replay.
	observe: ((actor: ActorTypes.Actor, onCommitted: ReplicationDomainOnCommitted) -> (() -> ())?)?,
}

export type LoadedReplicationEventDefinition = { read id: string, read payload: SharedNetworkingTypes.CompiledSchema }
export type LoadedReplicationDomainDefinition = {
	read id: string,
	read state: SharedNetworkingTypes.CompiledSchema,
	read events: { LoadedReplicationEventDefinition },
	read audience: ReplicationAudience,
	read snapshot: (actor: ActorTypes.Actor) -> any,
	read observe: ((actor: ActorTypes.Actor, onCommitted: ReplicationDomainOnCommitted) -> (() -> ())?)?,
}

export type PreparedReplicationDomainCatalog = {
	read definitionsById: { [string]: LoadedReplicationDomainDefinition },
	read orderedDefinitions: { LoadedReplicationDomainDefinition },
}

-- Framework-private input for building catalog-dependent built-in projections.
-- These are validated owned snapshots; public registries are still unloaded.
export type ReplicationDomainBuildCatalogs = {
	read tags: { TagTypes.TagDefinition },
	read resources: { ResourceTypes.LoadedResourceDefinition },
	read actions: { ActionTypes.LoadedActionDefinition },
}

export type BuiltInReplicationDomainBuilder = {
	Build: (catalogs: ReplicationDomainBuildCatalogs) -> ({ ReplicationDomainDefinition }?, string?),
}

export type ReplicationDomainRegistry = {
	Get: (domainId: string) -> LoadedReplicationDomainDefinition?,
	GetAll: () -> { LoadedReplicationDomainDefinition },
	GetAllById: () -> { [string]: LoadedReplicationDomainDefinition },
	IsLoaded: () -> boolean,
}

-- Publication is exclusively startup-owned; no runtime Register API.
export type InternalReplicationDomainRegistry = ReplicationDomainRegistry & {
	Prepare: (definitions: { ReplicationDomainDefinition }) -> (PreparedReplicationDomainCatalog?, string?),
	Publish: (catalog: PreparedReplicationDomainCatalog) -> (boolean, string?),
	_resetForTests: () -> (),
	_RollbackStartup: () -> (),
}

return types
