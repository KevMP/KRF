---
sidebar_position: 3
---

# Actor replication lifecycle

KRF turns authoritative Actor publication into a separate reliable stream for each ready client. Roblox owns physical Model replication and `StreamingEnabled` independently.

Default client startup establishes protocol readiness but installs no Actor-data consumer. Actor packets are rejected before decoding or assembly, with one `ActorStreamConsumerMissing` warning. Public Actor views, client state accessors, semantic event subscriptions, and client resync requests are unavailable.

## Awareness and identity

The server tracks every ready client as aware of every registered Actor. A client joining later gets streams for the current Actors, and registering another Actor creates streams for the current ready clients. This server-side awareness does not imply that the client has consumed Actor data. Connection closure releases that connection's streams.

`actor:GetId()` is the Actor's public runtime identity. Networking establishes a private connection-local handle for recurring traffic. Handles are never reused within a connection and are not game API. A respawn creates a new Actor identity.

## Baseline, live work, and recovery

1. After readiness is acknowledged, KRF captures an Actor's current canonical truth and filters its domains for the recipient. Joining or recovering clients do not rerun game snapshot callbacks.
2. Networking sends that baseline in bounded chunks before sending live work for the Actor.
3. Visible committed state and semantic events follow the baseline in Actor order. State-only work may coalesce; required event boundaries remain ordered.
4. If queued work exceeds its limits or a live record repeatedly exceeds the complete delivery budget, KRF discards obsolete unsent history and captures a newer baseline. A temporarily small budget waits. Recovery restores current truth; occurrences before that capture are not replayed.
5. Unregistering an Actor discards unsent work and reliably retires its awareness and handle.

Each recipient has an independent revision sequence for each Actor. Filtering and state coalescing happen before revision allocation, so hidden Owner work consumes no revision for other clients. A complete replacement baseline establishes a newer authoritative revision.

Oversized baselines, exhausted stream counters, and failed reliable sends halt the affected recipient's Actor stream and emit a warning. Automatic baseline recovery handles oversized live work and queue pressure; it does not restart a halted stream. The server Actor remains registered even when delivery fails.

Terminal cleanup is sent reliably and retried before pending transfer capacity is reused, so halted Actors do not indefinitely block unrelated transfers. Cleanup preserves Actor awareness and any existing Model binding.

## All and Owner audiences

| Audience | Eligible recipient |
| --- | --- |
| `All` | Every ready client aware of the Actor |
| `Owner` | The Player whose current Character is the Actor's registered Model |

Owner filtering uses direct Player and Actor objects. Numeric user ids do not establish ownership, and a later session with the same user id inherits no association. NPCs and Actors without a current Player association have no Owner recipient.

A Character change reconciles both affected Actor streams. The previous Character's replacement baseline excludes Owner domains; the new registered Character's baseline includes their current truth. Unregistered Character Models create no Actor association. Other recipients keep their existing streams.

Audience filters values and occurrences, not protocol metadata: every client still receives the same schema catalog.

## Model streaming

Physical Model arrival is independent of server awareness. A Model can arrive before or after its Actor stream starts. Streaming it out does not retire or reset that stream; Actor teardown or connection closure ends it. Default client startup exposes no local Actor record or Model-to-Actor lookup.

Successful Actor registration installs framework identity metadata before returning; teardown removes it. Model clones do not inherit that metadata. Leave it under framework ownership and register new gameplay Models through Actor Runtime.

## Related

- [Networking startup](./startup)
- [Replication domains](./replication-domains)
- [Actor Runtime](../Actor/actor-runtime)
