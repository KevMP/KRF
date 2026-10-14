---
sidebar_position: 3
---

# Actor replication lifecycle

KRF turns authoritative Actor publication into a separate reliable stream for each ready client. Roblox owns physical Model replication and `StreamingEnabled`; KRF associates those Models with Actor identities independently.

## Awareness and identity

Every ready client becomes aware of every registered Actor. A client joining later receives the current Actors, and registering another Actor creates awareness for the current ready clients. Connection closure releases that connection's streams.

`actor:GetId()` is the Actor's public runtime identity. Networking establishes a private connection-local handle for recurring traffic. Handles are never reused within a connection and are not game API. A respawn creates a new Actor identity.

## Baseline, live work, and recovery

1. After readiness is acknowledged, KRF captures an Actor's current canonical truth and filters its domains for the recipient. Joining or recovering clients do not rerun game snapshot callbacks.
2. Networking sends that baseline in bounded chunks. The client assembles and validates it separately before delivering complete truth to its internal consumer.
3. Visible committed state and semantic events follow the baseline in Actor order. State-only work may coalesce; required event boundaries remain ordered.
4. Excessive pending work cancels obsolete unsent history and captures a newer baseline. Recovery restores current truth; occurrences before that capture are not replayed.
5. Unregistering an Actor discards unsent work and reliably retires its awareness and handle.

Each recipient has an independent revision sequence for each Actor. Filtering and state coalescing happen before revision allocation, so hidden Owner work consumes no revision for other clients. A complete replacement baseline establishes a newer authoritative revision.

These streams currently feed framework-private decoded-record seams. KRF does not expose a public ActorView, client domain-state application, semantic event subscriptions, or client resync requests. Declaring a domain does not create a client gameplay accessor.

## All and Owner audiences

| Audience | Eligible recipient |
| --- | --- |
| `All` | Every ready client aware of the Actor |
| `Owner` | The Player whose current Character is the Actor's registered Model |

Owner filtering uses direct Player and Actor objects. Numeric user ids do not establish ownership, and a later session with the same user id inherits no association. NPCs and Actors without a current Player association have no Owner recipient.

A Character change reconciles both affected Actor streams. The previous Character's replacement baseline excludes Owner domains; the new registered Character's baseline includes their current truth. Unregistered Character Models create no Actor association. Other recipients keep their existing streams.

Audience filters values and occurrences, not protocol metadata: every client still receives the same schema catalog.

## Model streaming

Actor awareness and local Model presence have separate lifetimes. A Model can arrive before or after awareness. Streaming it out removes only its local binding; it does not remove the Actor record or reset the stream. Streaming it back in restores the binding. Actor removal wins over a stale Model still present locally.

Successful Actor registration installs framework identity metadata before returning; teardown removes it. Model clones do not inherit that metadata. Leave it under framework ownership and register new gameplay Models through Actor Runtime.

## Related

- [Networking startup](./startup)
- [Replication domains](./replication-domains)
- [Actor Runtime](../Actor/actor-runtime)
