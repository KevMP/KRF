--!strict
local ActorTypes = require(script.Parent.Parent.Actor.types)
local NetworkingTypes = require(script.Parent.Parent.Parent.shared.Networking.types)

local types = {}

export type ReplicationAudience = "All" | "Owner"
export type ReplicationEventDefinition = { id: string, payload: NetworkingTypes.SchemaDefinition }
export type ReplicationDomainEvent = { id: string, payload: any }
export type ReplicationDomainOnCommitted = (events: { ReplicationDomainEvent }?) -> ()

export type ReplicationDomainDefinition = {
	id: string,
	state: NetworkingTypes.SchemaDefinition,
	events: { ReplicationEventDefinition }?,
	audience: ReplicationAudience?,
	-- Complete recoverable current truth. Actor-only, synchronous, and non-yielding.
	snapshot: (actor: ActorTypes.Actor) -> any,
	-- Networking attaches this adapter later. Call onCommitted synchronously after
	-- authority commits and before consumer callbacks; events preserve occurrence order.
	-- Capture/validate event payloads before returning. No historical event replay.
	observe: ((actor: ActorTypes.Actor, onCommitted: ReplicationDomainOnCommitted) -> (() -> ())?)?,
}

export type LoadedReplicationEventDefinition = { read id: string, read payload: NetworkingTypes.CompiledSchema }
export type LoadedReplicationDomainDefinition = {
	read id: string,
	read state: NetworkingTypes.CompiledSchema,
	read events: { LoadedReplicationEventDefinition },
	read audience: ReplicationAudience,
	read snapshot: (actor: ActorTypes.Actor) -> any,
	read observe: ((actor: ActorTypes.Actor, onCommitted: ReplicationDomainOnCommitted) -> (() -> ())?)?,
}

export type PreparedReplicationDomainCatalog = {
	read definitionsById: { [string]: LoadedReplicationDomainDefinition },
	read orderedDefinitions: { LoadedReplicationDomainDefinition },
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
}

return types
