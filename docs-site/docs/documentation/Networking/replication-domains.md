---
sidebar_position: 2
---

# Replication domains

A replication domain declares an approved Actor-scoped projection of authoritative state and semantic events. Supply domains through `Server.Init({ replicationDomains = ... })`, separately from controller definitions.

| Concern | Owner |
| --- | --- |
| Authoritative gameplay state and mutation | Controller or gameplay system |
| State projection, event schemas, observation adapter, audience | Domain definition |
| Immutable catalog and schema admission | KRF startup |
| State capture, structural comparison, and buffer serialization | Networking caller; game code supplies no packets |

One domain can read several authoritative systems, and several domains can project related state for different audiences. A controller does not require a matching domain.

Catalog loading registers schemas and callback contracts. It does not attach observers, call projections, or send Actor state.

## Domain definition

| Field | Contract |
| --- | --- |
| `id` | Unique non-empty string across framework and game domains; prefer game names such as `Game.CombatState` |
| `state` | One complete recoverable [state schema](./schemas) |
| `snapshot(actor)` | Synchronous, non-yielding projection returning current truth for that schema |
| `events` | Optional dense array of `{ id, payload }` definitions; defaults to empty |
| `audience` | `All` or `Owner`; defaults to `All` |
| `observe(actor, onCommitted)` | Optional synchronous attachment adapter returning an optional disconnect callback |

`snapshot` takes only the Actor. Its result is recipient-independent, so one projection can serve every eligible recipient. Declare separate public and private domains when their data or audiences differ: `All` declares all recipients, while `Owner` declares the Actor's owning player.

A snapshot contains everything needed to recover the domain's current truth. Recovery must not depend on replaying events. Event ids are unique within their domain; different domains can use the same event id. Each event has its own bounded payload schema.

Definitions contain semantic fields only. Packet opcodes, Remote instances, numeric wire ids, revisions, offsets, and flush settings are not domain fields. Catalog order has no wire identity.

## Committed observation

An observation adapter accepts the Actor and an `onCommitted` callback supplied by its networking attachment caller. It subscribes to the authoritative system's synchronous committed-mutation seam and may return a disconnect function for detachment. The seam's name and implementation belong to that system.

1. The authoritative mutation fully commits.
2. The system synchronously invokes its committed observers before consumer callbacks can perform reentrant work.
3. The domain calls `onCommitted()` or `onCommitted(events)`.
4. The caller accounts for the complete current snapshot and captures event payloads before control returns.

`onCommitted()` reports a committed mutation, not a precomputed state patch. `onCommitted(events)` adds ordered occurrences associated with the same mutation; those occurrences are not inferred from state comparison or replayed by snapshots. The callback's payload boundary is erased in Luau, but values still follow their declared schemas.

Projection and observation must not yield or defer ordinary capture to Heartbeat or task scheduling. An asynchronous Signal is insufficient if consumer work can obscure the commit boundary. A framework-owned commit group can defer state capture only until that same non-yielding Actor transaction closes.

Omit `observe` for state that stays static for the Actor's lifetime. Catalog loading preserves callback references without invoking them; gameplay state captured by those callbacks can remain live while the catalog stays immutable.

## Static domain example

This domain projects an Actor's stable identity and needs no mutation observer.

```lua
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local Server = require(KRF.server)
local Schema = require(KRF.shared.Networking.Schema)
local ActorTypes = require(KRF.server.Actor.types)
local ReplicationTypes = require(KRF.server.Replication.types)

local identityDomain: ReplicationTypes.ReplicationDomainDefinition = {
	id = "Game.Identity",
	state = Schema.Struct({ actorId = Schema.String(64) }),
	snapshot = function(actor: ActorTypes.Actor): any
		return { actorId = actor:GetId() }
	end,
}

local started, failure = Server.Init({ replicationDomains = { identityDomain } })
if not started then
	local detail = if failure then failure.system .. ": " .. failure.reason else "Unknown startup failure"
	error(detail)
end
```

## Startup and ownership

Omitting the game catalog means no game-defined domains. KRF combines framework and game definitions before validation. Invalid ids, duplicate ids, malformed events, invalid schemas or audiences, and missing callbacks reject startup before publication.

Successful startup publishes one immutable domain catalog for the server lifetime. Mutating source domains, event arrays, or schema tables cannot change loaded contracts. [Registry reads](/api/Networking/replication-domain-registry) return immutable catalog metadata; games cannot register or replace domains during runtime.

## Related

- [Bounded schemas](./schemas)
- [Initializing KRF](../initializing-krf)
- [Replication Domain Registry API](/api/Networking/replication-domain-registry)
