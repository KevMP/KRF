---
sidebar_position: 0
---

# Networking startup

KRF owns the transport and protocol setup for the server and each client. Your game supplies bounded domain definitions during server startup and calls `Client.Init()` once on each client.

## Ownership

| Owner | Responsibility |
| --- | --- |
| Game startup | Supply controller and domain definitions; handle initialization failures |
| Replication domain catalog | Describe approved state shapes and semantic event payloads |
| Networking | Compile codecs, assign protocol codes, create transport, and establish client readiness |
| Controllers | Own live Actor state and gameplay mutations |

The framework creates one reliable `RemoteEvent` and one reserved `UnreliableRemoteEvent`. The handshake uses the reliable transport; the unreliable transport has no gameplay behavior. All framework packets, including the bootstrap catalog, are buffers. Games do not create, rename, replace, or send directly through these remotes, and KRF creates no `RemoteFunction` for startup.

## Initialize both sides

Follow the server Script and client LocalScript patterns in [Initializing KRF](../initializing-krf). Keep each call at one startup boundary and continue dependent setup only after it returns successfully.

1. `Server.Init(config)` validates the domain catalog, compiles its state and event codecs, and prepares an immutable global protocol catalog before activating the transport. It does not yield.
2. `Client.Init()` waits for the framework transport within a bounded deadline. It installs its receive listener before requesting bootstrap data.
3. The server checks protocol compatibility and sends the prepared catalog. The client reconstructs its codecs once and finishes framework consumer setup before declaring readiness.
4. The server marks the client ready and sends its acknowledgement before notifying framework readiness observers. `Client.Init()` returns success only after receiving that acknowledgement.

Repeated bootstrap requests while the server is waiting for readiness do not resend the catalog or restart setup. Duplicate readiness messages do not repeat the acknowledgement or readiness notification. Removing a player clears that connection's readiness.

Server and client must have exactly matching internal protocol versions. This compatibility check is independent of package semantic versioning; it does not negotiate a reduced protocol.

## Understand the catalog boundary

Domain codes are assigned in sorted domain-id order; event codes are assigned in sorted event-id order within each domain. Every client receives the same catalog. KRF reuses the prepared bootstrap buffer across clients and compiles codecs once per schema on the server and once during each client's reconstruction.

The bootstrap carries domain and event identities, protocol codes, and semantic schema definitions. It does not carry server callbacks, controllers, Actors, or current gameplay values. Large legal schema bounds remain exact during serialization; an encoded codec's maximum size stays within the schema's conservative byte bound.

`audience = "Owner"` describes eligibility for Actor data; it does not hide a domain's identity or schema from other clients. Treat protocol metadata as shared. Live state remains in server controllers.

Successful initialization establishes protocol readiness. The current runtime does not attach domains to Actors, call `snapshot` or `observe`, publish Actor snapshots or events, construct client Actor views, or provide a gameplay command API. Declaring a domain therefore does not make its state visible on a client.

## Handle startup failures

Both entrypoints accept one attempt, including after failure. Fix the configuration or deployment and start a fresh server or client session rather than retrying the same module.

Server protocol preparation rejects catalogs that exceed the bounded bootstrap packet budget. A transport collision also fails startup. Failed publication rolls back the registries and framework transport created by that startup operation; pre-existing conflicting instances are preserved.

Client discovery and the handshake share one deadline. A failure disconnects startup listeners and releases installed framework consumers. Late packets cannot turn a failed attempt into success. Rejection packets use a small fixed set of framework reason codes, so diagnostic strings cannot expand a handshake reply.

Use `failure.system` and `failure.reason` to report the failed stage. For `ProtocolMismatch`, deploy matching server and client code. For `TransportUnavailable` or `InvalidTransport`, check server startup and transport ownership. See the [Client API](/api/Client/#init) for the remaining failure categories.

## Related

- [Initializing KRF](../initializing-krf)
- [Bounded schemas](./schemas)
- [Replication domains](./replication-domains)
- [Server API](/api/Server/#init)
- [Client API](/api/Client/#init)
