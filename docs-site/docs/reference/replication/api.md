---
title: Replication domains API
sidebar_label: API
---

# Replication domains API

Register `{KRF.ReplicationDomainDefinition}` through `Server.Init({ replicationDomains = ... })`. Definitions are immutable after startup; no public runtime registration or replacement API is supplied.

## ReplicationDomainDefinition

| Field | Type / contract |
| --- | --- |
| `id` | Unique nonempty string |
| `state` | Required `SchemaDefinition` for the complete recoverable state |
| `events` | Optional dense array of `{ id: string, payload: SchemaDefinition }`; defaults empty |
| `audience` | `"All"` (default) or `"Owner"` |
| `snapshot` | `(actor: Actor) -> any`; synchronous, non-yielding, schema-valid current state |
| `observe` | Optional `(actor: Actor, onCommitted) -> (() -> ())?`; synchronous subscription adapter, optional disconnect return |

Event IDs are unique within the domain. `KRF.Tags`, `KRF.Resources` and `KRF.Actions` are reserved even when an empty visible catalog omits the corresponding built-in domain. Definitions reject unknown fields. Callback references remain server-local; schema metadata is shared with clients.

### Committed observation

```lua
onCommitted(events: {{id: string, payload: any}}?) -> ()
```

Call synchronously after projected gameplay state commits, before public callbacks. Nil/empty events report state alone. KRF copies and validates ordered event payloads during the call. A standalone notification also captures state before returning; inside a framework commit spanning several domains, KRF captures their final state together when the outer commit closes. No-op state with no events does not advance publication.

Registration invokes each snapshot and then its subscription after Controllers attach. Snapshot errors/yields, invalid snapshots, and subscription errors/yields reject registration and release subscriptions already acquired. An observer adapter must return nil or a disconnect function; KRF calls supplied disconnects during teardown, before destroying Controllers. Disconnects must also complete without yielding.

## ReplicationDomainRegistry

Server-side dot calls on `KRF.ReplicationDomainRegistry`:

| Signature | Return value |
| --- | --- |
| `Get(domainId: string) -> LoadedReplicationDomainDefinition?` | Frozen definition or nil |
| `GetAll() -> {LoadedReplicationDomainDefinition}` | Frozen array in catalog order, including built-in entries; empty before publication |
| `GetAllById() -> {[string]: LoadedReplicationDomainDefinition}` | Frozen lookup map |
| `IsLoaded() -> boolean` | Whether startup published the catalog |

Loaded definitions contain normalized audience, compiled state/event schemas and callback references. Compiled schema representation and startup preparation/publication are framework infrastructure.

## DomainView

Obtain a client domain with `actorView:GetDomain(domainId) -> DomainView?`.

| Signature / member | Contract |
| --- | --- |
| `domain:GetId() -> string` | Domain ID |
| `domain:GetState() -> any` | Current immutable schema-owned state; nil after the domain is destroyed |
| `domain:GetEvent(eventId: string) -> Event<any>?` | Declared event carrying its immutable payload; nil for an unknown ID or destroyed domain |
| `domain.OnChanged: Event<DomainChange>` | `{ previous, current, source }` after state installation |

`DomainChange.source` is `"Baseline"` or `"Commit"`. Equal state does not emit a change, including during replacement. Newly created domains arrive with initial state and do not emit an initial OnChanged. Baselines do not synthesize historical semantic events.

For one published Actor update, all affected state and indexes are installed before notifications. Domain change notifications are issued in domain ID order, then semantic events in their captured occurrence order. A callback can reenter gameplay or yield; its completion is not a barrier. Use [ActorView membership and availability events](../actors/client-views-api) to own subscriptions as visible domains change. Removed domains stop notifying; retaining their old Event or view does not restore membership.

## Delivery and audience

| Contract | Guarantee |
| --- | --- |
| `All` | Eligible for all ready clients aware of the Actor |
| `Owner` | Eligible only for the Player whose current Character is exactly the registered Model; a Character association change reconciles visible domain membership |
| Model streaming | Independent of Actor stream lifetime; nil local Model does not imply unavailable state |
| Continuous stream | Baseline precedes live work; committed occurrences retain order; state-only work may coalesce |
| Recovery | Replaces current truth and may discard obsolete occurrence history |
| Terminal stream failure | Retires domain truth and makes the affected client ActorView unavailable |

Streams and counters are framework-owned. Games do not set wire IDs, revisions, transport objects or flush budgets in definitions. Oversized baselines and terminal send failures cannot be repaired by assuming every server occurrence will eventually replay.

## Runtime capture failures

| Failure | Behavior |
| --- | --- |
| `PublicationSnapshotError:<domain>`, `PublicationSnapshotYielded:<domain>` | Snapshot callback threw or suspended |
| `InvalidPublicationSnapshot:<domain>` | Snapshot did not match its state schema |
| `PublicationObserveError:<domain>`, `PublicationObserveYielded:<domain>` | Subscription adapter threw or suspended during registration |
| `InvalidPublicationEvent:<domain>` | Malformed occurrence array, undeclared event or invalid payload |

During Actor registration these failures reject the attempted registration. During a later notification, capture failures raise through the synchronous publication call and preserve the last valid captured state. Gameplay mutations already committed are not rolled back. A later valid notification can reconcile current state without replaying rejected events.

When a failed framework commit touched several domains, KRF retains their recovery dependency: a later notification touching a member retries the affected group together. Unrelated groups can still publish. Persistent producer faults leave that group at its last valid state; there is no background polling retry.

## Startup failures

| Reasons | Cause |
| --- | --- |
| `ReplicationDomainDefinitionsMustBeTable`, `ReplicationDomainDefinitionsMustBeArray`, `ReplicationDomainDefinitionMustBeTable` | Invalid catalog/entry shape |
| `ReplicationDomainIdMissing`, `ReplicationDomainIdMustBeString`, `ReplicationDomainIdCannotBeEmpty`, `DuplicateReplicationDomainId` | Invalid, reserved or repeated domain ID |
| `ReplicationDomainFieldUnknown`, `ReplicationDomainAudienceInvalid` | Unknown field or unsupported audience |
| `ReplicationDomainSnapshotMustBeFunction`, `ReplicationDomainObserveMustBeFunction` | Invalid callback |
| `ReplicationDomainStateMissing` | No state schema |
| `ReplicationEventsMustBeArray`, `ReplicationEventDefinitionMustBeTable` | Invalid event declarations |
| `ReplicationEventIdMissing`, `ReplicationEventIdMustBeString`, `ReplicationEventIdCannotBeEmpty`, `DuplicateReplicationEventId` | Invalid or repeated event ID |
| `ReplicationEventFieldUnknown`, `ReplicationEventPayloadMissing` | Invalid event field or missing payload schema |

[Schema failures](../schemas/api#failures) also propagate. Networking startup additionally rejects `PublicationEventTooLarge:<domain>:<event>` when an event schema's conservative encoded maximum exceeds 65,536 bytes. Aggregate protocol size limits also apply. These size failures report `system = "Networking"`; domain definition failures report `system = "ReplicationDomain"`.

Definitions are validated without invoking callbacks at startup; valid callback types do not guarantee valid runtime captures.
