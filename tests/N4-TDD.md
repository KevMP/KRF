# N4 red-phase contract

Source: [issue #74](https://github.com/KevMP/KRF/issues/74).

This branch adds executable contract tests and typed private stubs only. Existing
startup, Actor lifecycle, publication, transport, and client implementations are
unchanged. Implement the named `N4NotImplemented` seams and their lifecycle wiring
to make the suite green; do not skip specs or lower coverage thresholds.

## Test map

| Contract | Specs |
| --- | --- |
| Ready/Closed subscription, event-driven awareness, deduplication | `server/Networking/ActorAwareness.Readiness.spec.luau` |
| Direct Player identity, All/Owner visibility and reassociation | `server/Networking/ActorAwareness.Ownership.spec.luau` |
| Handle allocation, retirement, connection isolation, replacement admission | `server/Networking/ActorAwareness.Handles.spec.luau` |
| Canonical capture, sequence fence, chunking, replacement, pressure and fairness | `server/Networking/ActorAwareness.Baselines.spec.luau` |
| Filtered revisions, state coalescing, event barriers, immutable source commits | `server/Networking/ActorAwareness.Live.spec.luau` |
| Cancelled history, reliable removal and destroyed-runtime cleanup | `server/Networking/ActorAwareness.Removal.spec.luau` |
| Real N2 ACK ordering and real Actor registration/rollback | `server/Networking/ActorAwareness.Integration.spec.luau` |
| Startup ownership, private Actor hooks and awareness rollback | `server/Networking/ActorAwareness.Startup.spec.luau` |
| Marker ownership, idempotency, conflict, cloning and destruction | `server/Networking/ActorModelMarker.spec.luau` |
| Complete generation assembly, bounds and conflicting identities | `client/ActorStream.Assembly.spec.luau` |
| N5 delivery seam, revision-gap scope, removal and handle retirement | `client/ActorStream.Records.spec.luau` |
| Marker arrival orders, stream-out/rebind, ambiguity and stale markers | `client/ActorStream.ModelBinding.spec.luau` |
| Logical records, patch semantics, Optional domain presence and codebooks | `shared/Networking/ActorStreamCodec.RoundTrips.spec.luau` |
| Packet truncation, foreign codes, schema bounds and Instance rejection | `shared/Networking/ActorStreamCodec.Hardening.spec.luau` |

All paths in the table are relative to `tests/`.

## Private seams and fixture choices

- Server awareness consumes real N3 canonical capture/commit notifications and a
  real prepared N2 catalog. The fixture injects private connection callbacks,
  direct Character-to-Player resolution and reliable sends. A separate spec
  bridges the real N2 handshake and checks ACK ordering.
- The client consumes a compiled Actor codec, discovery events and an N5 fake
  consumer. It delivers complete decoded truth and patches without applying them.
  Revision-gap detection deliberately stays with N5.
- Partial-patch codecs receive compiled N1 schemas explicitly. Existing N2 value
  codecs expose opaque Measure/Write/Read functions; those functions alone do not
  expose the field metadata required to encode/decode partial Struct/Map patches.
  Compile that metadata once from the admitted manifest on the client, and reuse
  the prepared domain schemas on the server.
- Limits are injected to test exhaustion/overload with small allocations. Test
  values are not proposed production defaults. No test locks wire opcodes,
  prefix widths, marker class/name/tag, or a starting revision/handle value.
- Exact failure strings introduced here are proposed framework-private stable
  results. Their spelling is not specified by the ticket and is not public API.
- Player fixtures follow existing KRF tests: Folder identities for injected
  adapters, and two table identities with equal UserId for the session-identity
  regression. Native Roblox Player/Character discovery needs an engine check.

## Ticket tensions and implementation decisions

- N4 excludes client resync request handling but requires a private server
  `RequestReplacementBaseline` seam. These specs cover admission/deduplication of
  that seam, leaving N5 control messages and revision-gap recovery out of scope.
- The ticket calls baseline generations connection-local while describing a
  monotonically increasing attempt per recipient/Actor. Specs require generation
  isolation and increasing generations on replacement of the same stream. They
  permit either a shared connection allocator or an independent stream allocator.
- Existing `RegisterActorOpts.ownerUserId` is a dead reservation, and the ticket
  expressly rejects promoting it into authority. The new suite uses direct Player
  objects. Removing that reservation and updating its API reference remain
  implementation work; the current `opts` argument is ignored by ActorRuntime.
- Shared public/owner projections are requested "where practical." Specs enforce
  immutability and correct recipient results without requiring internal table
  identity or a particular caching algorithm.
- A completed baseline establishes a revision, but the starting value is private.
  Server assertions use relative revision advancement and injected exhaustion
  bounds. Client fixture numbers are input records, not allocator expectations.

## Validation and remaining checks

Run `npm run test:unit` after focused changes and `npm test` before committing.
Expected red failures must come from N4 stubs or missing N4 lifecycle wiring,
not syntax errors, invalid fixtures, or regressions in existing suites.

Red-phase validation: `npm test` passes lint (zero errors/warnings/parse errors)
and typechecking, then reports 113 expected failures across the 14 new suites.
All 1,385 existing tests across 95 suites pass. Coverage instrumentation emits a
report, but the failing unit command prevents the coverage threshold stage from
running; no coverage improvement is claimed.

These specs do not prove real StreamingEnabled behavior, native marker
tag/discovery wiring, native Player Character change notifications, CPU/allocation
performance, or projection-cache efficiency. Add engine integration checks and
implementation-specific regression tests when those adapters exist. In particular,
real `ServerNetworking.Publish` must install/own N4 and wire private Actor lifecycle
hooks; a standalone runtime passing unit tests is insufficient.

Consumer documentation requested by the story belongs to the implementation
phase. N4 must not expose ActorViews or add client domain patch application here.
