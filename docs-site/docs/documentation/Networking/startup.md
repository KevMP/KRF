---
sidebar_position: 0
---

# Networking startup

KRF owns the transport and protocol setup for the server and each client. Your game supplies bounded domain, command and Hint definitions during server startup and calls `Client.Init()` once on each client.

## Ownership

| Owner | Responsibility |
| --- | --- |
| Game startup | Supply controller, domain, command and Hint definitions; handle initialization failures |
| Replication domain catalog | Describe approved state shapes and semantic event payloads |
| Networking | Compile codecs, assign protocol codes, create transport, attach server publication domains, and establish client readiness |
| Controllers | Own live Actor state and gameplay mutations |

The framework creates one reliable `RemoteEvent` and one `UnreliableRemoteEvent`. The handshake, Actor publications, and commands share the reliable transport; Hints in both directions use the unreliable transport for disposable presentation. All framework packets, including the bootstrap catalog, are buffers. Games do not create, rename, replace, or send directly through these remotes, and KRF creates no `RemoteFunction` for startup.

## Initialize both sides

Follow the server Script and client LocalScript patterns in [Initializing KRF](../initializing-krf). Keep each call at one startup boundary and continue dependent setup only after it returns successfully.

1. `Server.Init(config)` validates domain, command and Hint catalogs and their size bounds, compiles state, event, request, result and Hint payload codecs, and installs the immutable protocol catalog and server runtimes before returning success. It does not yield.
2. `Client.Init()` waits for the framework transport within a bounded deadline. It installs its receive listener before requesting bootstrap data.
3. The server checks protocol compatibility and sends the prepared catalog. The client reconstructs its codecs and installs its Actor decoder, ActorView consumer, command runtime and shared packet receiver before declaring readiness.
4. The server marks the client ready and sends its acknowledgement before notifying framework readiness observers. `Client.Init()` returns success only after receiving that acknowledgement.

Repeated bootstrap requests while the server is waiting for readiness do not resend the catalog or restart setup. Duplicate readiness messages do not repeat the acknowledgement or readiness notification. Removing a player clears that connection's readiness.

Server and client must have exactly matching internal protocol versions. This compatibility check is independent of package semantic versioning; it does not negotiate a reduced protocol.

## Understand the catalog boundary

Domain, event, command and Hint codebooks are deterministic and independent of declaration order. Every client receives the same catalog. KRF reuses the prepared bootstrap buffer across clients and compiles codecs once per schema on the server and once during each client's reconstruction. [Hint payload codecs](./hints) compile before READY; Hint send/receive owners and the unreliable client listener install before READY. Traffic received before readiness is disposable.

The bootstrap carries domain, event, command and Hint identities, Hint directions/modes, target modes, protocol codes, and semantic schema definitions. It does not carry server callbacks, controllers, Actors, or current gameplay values. Legal schema bounds remain exact during serialization. Startup rejects events above the publication limit, command request/result schemas above the [command payload limit](./commands#define-and-authorize-a-command), and Hint definitions that cannot fit one [unreliable packet](./hints#startup-validation-and-ownership).

`audience = "Owner"` describes eligibility for Actor data; it does not hide a domain's identity or schema from other clients. Treat protocol metadata as shared. Live state remains in server controllers.

Successful initialization establishes protocol readiness and installs server Actor publication and recipient streams. When an Actor registers, KRF captures its initial domain state and observes subsequent committed mutations; unregistering the Actor or resetting the server releases those observers.

Successful `Client.Init()` means the [ActorView runtime](./actor-views) is ready for future traffic. It does not wait for an Actor baseline or for a Roblox Model to arrive. Subscribe to registry lifecycle events and inspect existing views when initializing a client system. Use the [CommandRuntime](./commands) for client requests; ActorViews remain read-only.

Start consumer modules from the same successful startup boundary; those modules must not call `Client.Init()` again. Runtime Actor faults use the [ActorView lifecycle and recovery contract](./actor-views#initial-state-and-recovery), rather than restarting initialization.

## Handle startup failures

Both entrypoints accept one attempt, including after failure. Fix the configuration or deployment and start a fresh server or client session rather than retrying the same module.

Server protocol preparation rejects catalogs that exceed the bounded bootstrap packet budget. A transport collision also fails startup. Failed publication rolls back the registries and framework transport created by that startup operation; pre-existing conflicting instances are preserved.

Client discovery and the handshake share one deadline. A failure disconnects startup listeners and releases installed framework consumers. Late packets cannot turn a failed attempt into success. Rejection packets use a small fixed set of framework reason codes, so diagnostic strings cannot expand a handshake reply.

Use `failure.system` and `failure.reason` to report the failed stage. For `ProtocolMismatch`, deploy matching server and client code. For `TransportUnavailable` or `InvalidTransport`, check server startup and transport ownership. See the [Client API](/api/Client/#init) for the remaining failure categories.

## Related

- [Initializing KRF](../initializing-krf)
- [Bounded schemas](./schemas)
- [Replication domains](./replication-domains)
- [Hints](./hints)
- [Maintainer scheduling and diagnostics](./maintaining-networking)
- [Server API](/api/Server/#init)
- [Client API](/api/Client/#init)
