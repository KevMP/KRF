# Replication Types

Public replication types describe authored domains, semantic occurrences, committed notifications, and loaded registry metadata.

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ReplicationTypes = require(ReplicatedStorage.Packages.KRF.server.Replication.types)
```

`Actor` below is `KRF.server.Actor.types.Actor`. `SchemaDefinition` and `CompiledSchema` come from `KRF.shared.Networking.types`: the former is a [Schema](./schema) definition; the latter is immutable Networking-owned compiled metadata whose layout is private.

## Members

| Type | Contract |
| --- | --- |
| [`ReplicationDomainDefinition`](#replication-domain-definition) | Authored state, event schemas, callbacks, and audience |
| [`ReplicationEventDefinition`](#replication-event-definition) | One declared event id and payload schema |
| [`ReplicationAudience = "All" \| "Owner"`](#replication-audience) | Recipient eligibility metadata |
| [`ReplicationDomainOnCommitted = (events: {ReplicationDomainEvent}?) -> ()`](#replication-domain-on-committed) | Committed state notification with optional ordered occurrences |
| [`ReplicationDomainEvent`](#replication-domain-event) | One reported occurrence |
| [`LoadedReplicationEventDefinition`](#loaded-replication-event-definition) | Frozen event metadata with a compiled payload schema |
| [`LoadedReplicationDomainDefinition`](#loaded-replication-domain-definition) | Frozen normalized domain returned by the registry |

## ReplicationDomainDefinition {#replication-domain-definition}

```lua
export type ReplicationDomainDefinition = {
	id: string,
	state: SchemaDefinition,
	events: { ReplicationEventDefinition }?,
	audience: ReplicationAudience?,
	snapshot: (actor: Actor) -> any,
	observe: ((actor: Actor, onCommitted: ReplicationDomainOnCommitted) -> (() -> ())?)?,
}
```

| Field | Constraint/default |
| --- | --- |
| `id` | Non-empty string, unique across framework and game domains |
| `state` | Required valid bounded schema for complete recoverable state |
| `events` | Dense array of event definitions with unique ids within this domain; defaults to empty |
| `audience` | `All` or `Owner`; defaults to `All` |
| `snapshot` | Required synchronous, non-yielding function; result must match `state` |
| `observe` | Optional synchronous attachment function; may return a disconnect callback |

Unknown fields reject startup. KRF validates, copies, and freezes metadata before publication. Callback references are retained without being called during startup; state captured by their closures may remain live.

`snapshot` receives only the Actor, never a recipient. `any` is an erased Luau return boundary, not permission to return arbitrary network data. `observe` connects the controller's committed observers to KRF's supplied callback; see the [dynamic authoring example](/Networking/replication-domains#connecting-a-controller-to-a-domain).

## ReplicationEventDefinition {#replication-event-definition}

```lua
export type ReplicationEventDefinition = {
	id: string,
	payload: SchemaDefinition,
}
```

Only `id` and `payload` are permitted. The id must be a non-empty string unique within its domain; the payload must be a valid bounded schema. Different domains may reuse the same event id.

## ReplicationAudience {#replication-audience}

```lua
export type ReplicationAudience = "All" | "Owner"
```

`All` means all eligible recipients for that Actor. `Owner` means only its owning player is eligible. This metadata does not establish Actor awareness; omitted audience normalizes to `All`.

## ReplicationDomainOnCommitted {#replication-domain-on-committed}

```lua
export type ReplicationDomainOnCommitted = (events: { ReplicationDomainEvent }?) -> ()
```

KRF supplies this callback to `observe`. The domain calls it synchronously after authoritative mutation commits, before public gameplay callbacks. With no argument it reports the current-state boundary; with an event array it also reports ordered occurrences from that mutation. It accepts no state patch.

Snapshot projection and committed delivery must not yield. Event payloads must be captured and validated before returning. Snapshots recover state and do not replay events; see [state vs semantic events](/Networking/replication-domains#state-vs-semantic-events).

## ReplicationDomainEvent {#replication-domain-event}

```lua
export type ReplicationDomainEvent = {
	id: string,
	payload: any,
}
```

An occurrence passed to `onCommitted` names an event declared by that domain. `payload` must satisfy its declared payload schema; `any` only erases the Luau boundary. Array order preserves occurrence order.

## LoadedReplicationEventDefinition {#loaded-replication-event-definition}

```lua
export type LoadedReplicationEventDefinition = {
	read id: string,
	read payload: CompiledSchema,
}
```

Frozen event metadata. `payload` is compiled from the authored definition; game code does not depend on its internal representation or encoded byte layout.

## LoadedReplicationDomainDefinition {#loaded-replication-domain-definition}

```lua
export type LoadedReplicationDomainDefinition = {
	read id: string,
	read state: CompiledSchema,
	read events: { LoadedReplicationEventDefinition },
	read audience: ReplicationAudience,
	read snapshot: (actor: Actor) -> any,
	read observe: ((actor: Actor, onCommitted: ReplicationDomainOnCommitted) -> (() -> ())?)?,
}
```

Returned by [ReplicationDomainRegistry](./replication-domain-registry). All metadata and nested collections are frozen. `state` and event payloads are compiled schemas, `events` is always an array, and `audience` is always a supported value. `snapshot` and `observe` retain the authored callback references.

## Related

- [Replication domains guide](/Networking/replication-domains)
- [Schema API](./schema)
- [Replication Domain Registry](./replication-domain-registry)
