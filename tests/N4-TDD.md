# N4 contract suite

Source: [issue #74](https://github.com/KevMP/KRF/issues/74).

The red pass established the contracts below before implementation. This branch
now implements the private codec, awareness, assembly, association, discovery and
production lifecycle seams. N5 still owns public ActorViews, patch application,
revision expectations and client resync requests.

## Test map

| Contract | Specs |
| --- | --- |
| Ready/Closed subscription, event-driven awareness, deduplication | `server/Networking/ActorAwareness.Readiness.spec.luau` |
| Direct Player identity, All/Owner visibility and reassociation | `server/Networking/ActorAwareness.Ownership.spec.luau` |
| Handle allocation, retirement, connection isolation, replacement admission | `server/Networking/ActorAwareness.Handles.spec.luau` |
| Canonical capture, sequence fence, chunking, replacement, pressure and fairness | `server/Networking/ActorAwareness.Baselines.spec.luau` |
| Initial identity versus handle-only replacement and cancellation timing | `server/Networking/ActorAwareness.BaselineIdentity.spec.luau` |
| Cross-recipient join/replacement backlog fairness under small budgets | `server/Networking/ActorAwareness.RecipientFairness.spec.luau` |
| Filtered revisions, state coalescing, event barriers, immutable source commits | `server/Networking/ActorAwareness.Live.spec.luau` |
| Cancelled history, reliable removal and destroyed-runtime cleanup | `server/Networking/ActorAwareness.Removal.spec.luau` |
| Real N2 ACK ordering and real Actor registration/rollback | `server/Networking/ActorAwareness.Integration.spec.luau` |
| Startup ownership, private Actor hooks and awareness rollback | `server/Networking/ActorAwareness.Startup.spec.luau` |
| Production native Character association-source installation and cleanup | `server/Networking/ActorAwareness.Startup.spec.luau` |
| Production Step driver, injected budgets, native-frame scheduling and teardown | `server/Networking/ActorAwareness.Startup.spec.luau`, `server/Networking/AwarenessScheduling.spec.luau` |
| Marker ownership, idempotency, conflict, cloning and destruction | `server/Networking/ActorModelMarker.spec.luau` |
| Complete generation assembly, bounds and conflicting identities | `client/ActorStream.Assembly.spec.luau` |
| Pending-baseline admission and completed-generation monotonicity | `client/ActorStream.Admission.spec.luau` |
| Production pre-READY N4 installation, post-READY routing and startup cleanup | `client/Client.Init.ActorStream.spec.luau` |
| N5 delivery seam, revision-gap scope, removal and handle retirement | `client/ActorStream.Records.spec.luau` |
| Marker arrival orders, stream-out/rebind, ambiguity and stale markers | `client/ActorStream.ModelBinding.spec.luau` |
| Real server marker to native client discovery/binding bridge | `client/ActorStream.ModelDiscovery.Integration.spec.luau` |
| Logical records, patch semantics, Optional domain presence and codebooks | `shared/Networking/ActorStreamCodec.RoundTrips.spec.luau` |
| Packet truncation, foreign codes, schema bounds and Instance rejection | `shared/Networking/ActorStreamCodec.Hardening.spec.luau` |
| Native Character-source observation, session removal and cleanup | `server/Networking/NativePlayerAssociation.spec.luau` |
| Halted sends, failed captures, counter exhaustion and insufficient budgets | `server/Networking/ActorAwareness.Failures.spec.luau` |
| Uninstalled private lifecycle hooks | `server/Networking/ActorAwarenessLifecycle.spec.luau` |
| Real production handshake, baseline/live traffic and oversized truth | `server/Networking/ServerNetworking.ActorTraffic.spec.luau` |
| Physical batching, 1,200-Actor packet splitting and reentrant delivery | `server/Networking/ActorAwareness.Packets.spec.luau` |
| Early removal, corrupt assembly and native N5 consumer installation | `client/ActorStream.Failures.spec.luau` |
| Invalid native markers, identity mutations and observer cleanup | `client/ActorModelDiscovery.Validation.spec.luau` |
| Schema-specific patch rejection and allocation-free packet measurement | `shared/Networking/ActorPatchCompiler.spec.luau` |

All paths in the table are relative to `tests/`.

## Private seams and fixture choices

- Server awareness consumes real N3 canonical capture/commit notifications and a
  real prepared N2 catalog. The fixture injects private connection callbacks,
  direct Character-to-Player resolution and reliable sends. A separate spec
  bridges the real N2 handshake and checks ACK ordering.
- Reassociation specs emit an injected Model association-change event consumed by
  the runtime. They never call `RefreshPlayerAssociation` to trigger reconciliation.
  Teardown must release the subscription, and registration after a connection
  closes must avoid even checking historical recipients.
- Production client specs call `Client.Init` with its default native dependency
  table and leave `NativeClientDependencies.InstallConsumers` intact. Only
  transport, clock, timeout/resume and runtime/discovery factories are controlled.
  Real codec-produced Actor packets must reach the installed runtime after ACK;
  failure/reset must destroy the runtime and discovery, and stale callbacks halt.
- Production server startup specs emit scheduling events through an injected
  native scheduling adapter and observe the installed runtime's `Step` calls.
  Each call must use the configured byte/record budget. Teardown/rollback must
  stop the driver, including callbacks already queued before teardown. Separate
  native-frame specs exercise the scheduling adapter's event connection.
- Initial Begin carries `actorId` to establish the handle mapping; replacement
  Begin omits it and uses the known handle. Cancellation before any Begin is sent
  must retain initial identity. Cancellation after Begin was sent must omit it on
  recapture. Client replacement fixtures no longer resend identity; unknown
  handle-only Begins reject without inventing an Actor record.
- Native association production wiring is covered separately from the runtime's
  injected observer. The multiplayer fixture under `integration/N4Association`
  uses the real default native source, real engine-created Players, the real
  Character property, real ActorRegistry bindings and N3 canonical publication.
  Changing Character old-to-new must replace both affected Owner domain sets;
  changing to an unregistered Model must safely clear only the previous mapping.
- Cross-recipient fairness specs cover a late joiner and an earlier connection
  with many replacement baselines. Under a one-record budget, another recipient's
  already-live Actor must be serviced before the baseline backlog fully drains.
- The client consumes a compiled Actor codec, discovery events and an N5 fake
  consumer. It delivers complete decoded truth and patches without applying them.
  Revision-gap detection deliberately stays with N5.
- `maxPendingBaselines` limits concurrent incomplete assemblies. Completion and
  ActorRemove release capacity; rejected Begins consume none; replacing a pending
  generation occupies its existing slot. A completed generation remains a fence:
  same/older Begin rejects, while a newer generation can complete on the same record.
- Marker bridge specs use the actual `ActorModelMarker` and `ActorModelDiscovery`
  modules, the actual marker Instance and real hierarchy events. No independent
  fake Candidate is supplied to these bridge tests.
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
- `RegisterActorOpts.ownerUserId` had no framework consumer and has been removed.
  The optional `opts` parameter remains an empty compatibility shape; ownership
  uses direct Player objects and native Character changes.
- Shared public/owner projections are requested "where practical." Specs enforce
  immutability and correct recipient results without requiring internal table
  identity or a particular caching algorithm.
- A completed baseline establishes a revision, but the starting value is private.
  Server assertions use relative revision advancement and injected exhaustion
  bounds. Client fixture numbers are input records, not allocator expectations.

## Validation and remaining checks

Run `npm run test:unit` after focused changes and `npm test` before committing.
Historical red-phase validation: `npm test` passed lint (zero errors/warnings/parse errors)
and typechecking, then reported 147 expected failures across the 20 new suites.
All 1,385 existing tests across 95 suites passed. Coverage instrumentation emitted a
report, but the failing unit command prevented the coverage threshold stage from
running.

Implementation validation: `npm test` passes lint with zero warnings,
typechecking and all 1,569 tests across 123 suites, including the original 1,385
tests. Per-file coverage gates remain at 90% and pass. The docs-site
production build succeeds. The internal protocol compatibility version was bumped
for the Actor wire contract.

These unit specs do not prove real StreamingEnabled behavior across server/client
DataModels or CPU/allocation performance. Production lifecycle integration is
covered independently from runtime units. Canonical sequence caches reuse public
and Owner baseline bodies; immutable commit projections are built once per
visibility class. Packet measurement allocates no output buffer.

Consumer documentation is in the Networking Actor replication guide. No public
ActorView or client domain patch application is added.

## Real Character source fixture

Build `n4-association-test.project.json` into
`build/KRF-N4-Association-Tests.rbxl`. In that place's Edit DataModel, run
`scripts/run-n4-association-tests.luau` through a command bar or local plugin with
StudioTestService access, following the existing native networking launcher pattern.
It creates two real client sessions and ends with a structured result. The fixture
never calls `RefreshPlayerAssociation` or manually emits the association observer.
It also checks that domain snapshots are not rerun for ownership reconciliation.

The two-client multiplayer fixture passes with real engine Players and real
Character property transitions, including an unregistered Character. Its result
is `{ success = true, snapshots = 4 }`: only the initial canonical captures ran.
`npm test` runs the unit/production-wiring contracts; this separate Edit-mode
fixture uses `scripts/n4-association-test-plugin.server.luau` or the command-bar
launcher above.
