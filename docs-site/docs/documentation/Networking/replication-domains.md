---
sidebar_position: 2
---

# Replication domains

A replication domain declares the Actor state and gameplay occurrences your game approves for replication. Your controller owns gameplay; the domain defines its state projection and committed-observation callback contract.

Use custom domains for game-owned state. KRF automatically publishes assigned ClientVisible Resources through [ResourcesView](../Resource/resource-views) and active ClientVisible Tags through [TagsView](../Tags/tag-views). Stamina, Mana, and similar meters belong to Resources; use these built-in projections for framework-owned state. A built-in Actions domain is not available yet; Action `ClientVisible` metadata alone does not publish state.

Supply domains through `Server.Init({ replicationDomains = ... })`, separately from controller definitions. Startup installs the server publication runtime and prepares schema metadata for the [networking handshake](./startup). Registering an Actor captures each domain and attaches its committed observer before the Actor is enabled or public registration callbacks run.

[Actor replication](./actor-replication) filters and sends the resulting records to ready clients. [ActorViews](./actor-views) expose each visible domain's immutable current state and declared semantic events automatically after a complete baseline.

## Domain definition {#domain-definition}

Supply these fields in a domain definition. Construct `state` and event payload schemas with [Schema](./schemas).

| Field | Authoring contract |
| --- | --- |
| `id` | Non-empty string, unique across framework and game domains |
| `state` | Required bounded schema for complete recoverable state |
| `events` | Dense array of `{ id, payload }` definitions; ids are unique within the domain, and payloads have bounded schemas; defaults to empty |
| `audience` | `All` or `Owner` eligibility metadata; defaults to `All` |
| `snapshot(actor)` | Required synchronous, non-yielding function returning complete state matching `state` |
| `observe(actor, onCommitted)` | Optional synchronous subscription adapter; may return a disconnect function. Call `onCommitted()` for state alone or `onCommitted(events)` for ordered occurrences |

Unknown domain and event fields reject startup. Startup validates schemas, callback types, and the maximum encoded size of each event payload without invoking callbacks. Actor registration then calls each `snapshot` and optional `observe`; a thrown, yielding, or invalid result rejects that registration and releases earlier domain subscriptions. Returned state and event payloads must match their declared schemas.

## State vs semantic events

| Concept | Meaning | Example |
| --- | --- | --- |
| State | What is true now | `title = "Champion"` |
| Semantic event | Something happened | `TitleAwarded`, with `{ title = "Champion" }` |

`snapshot(actor)` returns the complete current state. A snapshot can recover the equipped title; it cannot tell you when titles were awarded. Snapshots do not replay events, and recovery must never require their history.

Declare occurrences separately, with an id and a bounded payload schema:

```lua
events = {
	{ id = "TitleAwarded", payload = Schema.Struct({ title = Schema.String(64) }) },
},
```

The committed callback contract represents an occurrence alongside the state notification as:

```lua
onCommitted({
	{ id = "TitleAwarded", payload = { title = "Champion" } },
})
```

Under this contract, `onCommitted()` reports a mutation with no semantic events. `onCommitted(events)` reports the same state boundary plus ordered occurrences. The domain supplies neither a state patch nor packets. Events are explicit, never inferred from a changed state value.

## Committed-observation callback contract

KRF captures each domain after controllers attach and subscribes through `observe(actor, onCommitted)`. The adapter may return a disconnect function, which KRF calls before destroying the Actor's controllers.

For a changing domain:

1. Commit all gameplay state included in the projection.
2. Notify committed observers synchronously, before public gameplay callbacks can perform reentrant mutations.
3. Call `onCommitted()` for state alone, or `onCommitted(events)` with the ordered occurrences from that boundary.

KRF captures the complete state and event payloads before `onCommitted` returns. State changes and events from that boundary share one Actor sequence. An unchanged snapshot with no events produces no new sequence. Invalid events or snapshots reject the publication without changing the last captured state; a later valid notification can reconcile it.

`snapshot`, `observe`, observer delivery, and `onCommitted` must be synchronous and non-yielding. Do not use Heartbeat, `task.spawn`, `task.defer`, or an asynchronous Signal to deliver committed notifications. Later gameplay mutations must not alter captured event payloads.

The committed-observer method belongs to your game; KRF prescribes no controller method name. The domain adapts that method to `onCommitted`. Omit `observe` only for state that remains static for the Actor's lifetime.

## Audience and ownership

`audience = "All"` means every ready client aware of that Actor; `"Owner"` means only the Player whose current Character is its registered Model. `All` is the default. Owner eligibility uses direct runtime objects, never numeric user ids. Awareness remains independent of audience: a client can know an Actor exists without receiving its Owner domains. See [Actor replication](./actor-replication) for Character changes, replacement baselines, and Model streaming.

`snapshot` receives only the Actor, so its result is independent of the recipient. Use separate public and private domains when their projections differ. One domain may read several systems, and a controller may have no domain.

KRF combines framework and game domains before startup validation. Duplicate domain ids, malformed events, invalid schemas or audiences, and missing required callbacks fail before publication. Event ids must be unique within a domain; different domains may reuse an event id.

`KRF.Tags` and `KRF.Resources` are reserved for the built-in projections, including when an empty visible catalog causes either protocol domain to be omitted. Game definitions cannot claim these ids. ServerOnly Tag and Resource ids are excluded before their visible schemas are compiled.

Successful startup publishes immutable catalog metadata. Source-table edits cannot change the loaded contract; live gameplay state stays in the controller. Games cannot register or replace domains at runtime. Definitions contain semantic fields only: games supply no Remote references, wire ids, byte offsets, revisions, or flush settings.

All clients receive the same domain and event schema catalog during protocol startup, including domains whose audience is `Owner`. The bootstrap excludes the stored server callbacks and live Actor values; audience metadata does not conceal schema definitions.

## Related

- [Bounded schemas](./schemas)
- [Networking startup](./startup)
- [Replication Domain Registry API](/api/Networking/replication-domain-registry)
