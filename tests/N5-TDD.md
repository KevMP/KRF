# N5 contract suite

Source: [issue #75](https://github.com/KevMP/KRF/issues/75), grounded in the KRF
charter and the implemented N1–N4 schema, bootstrap, publication and Actor-stream
contracts. The suite began as a **red phase** with typed placeholders. The current
branch implements immutable views, atomic revision application, automatic startup
installation and bounded server recovery. Historical red results remain below
to distinguish the original missing behavior from implementation regressions.

## Contract map

All paths below are relative to `tests/`. The section numbers refer to issue #75.

| Ticket contract | Specifications |
| --- | --- |
| Public ActorView/DomainView/registry shape; no wire or future typed API (§1–6, 23) | `client/ActorView.Creation.spec.luau`, `client/ActorView.State.spec.luau` |
| Immutable public registry surface; private state owners and staged installation/notification | `client/ActorViewRegistry.Immutability.spec.luau`, `client/ActorView.Ownership.spec.luau` |
| Complete initial publication; no partial view or synthetic domain history; identity uniqueness (§11–13) | `client/ActorView.Creation.spec.luau`, `client/ActorView.Commits.spec.luau` |
| Read-only recursive Struct/Map/Array snapshots; retained snapshots; immutable change records and event payloads (§7–10) | `client/ActorView.State.spec.luau`, `client/ActorStatePlan.spec.luau` |
| Schema-aware scalar/Struct/Map/Optional/Array application; unchanged paths; copy-on-write (§9, 43, 48) | `client/ActorStatePlan.spec.luau`, `client/ActorView.State.spec.luau` |
| Atomic multi-domain commit; state and revision installed before Fire; rollback; deterministic notifications; event-only revisions (§14–17) | `client/ActorView.Commits.spec.luau` |
| Authoritative semantic Fire order within/across commits; yielding and throwing consumers (§18–19, 45) | `client/ActorView.Commits.spec.luau`, `client/ActorView.Scheduling.spec.luau` |
| Exact-next revision; duplicate/stale/gap rejection; invalid/counter boundary handling (§20–23) | `client/ActorView.Recovery.spec.luau` |
| One request per recovery episode; last good truth; no incremental replay/backlog; isolated Actors; bounded send failures (§24, 26–28, 44) | `client/ActorView.Recovery.spec.luau`, `client/ActorView.Work.spec.luau` |
| Private compact buffer framing; malformed/truncated/trailing/foreign traffic rejection (§24) | `shared/Networking/ResyncCodec.spec.luau` |
| Ready/known-aware/removing/pending admission; deduplication; per-client/per-Actor bounds and disconnect cleanup (§25–26) | `server/Networking/ResyncRuntime.spec.luau`, `server/Networking/Resync.ActorViews.Integration.spec.luau` |
| Production Reliable routing; handler ownership and teardown (§24–25) | `server/Networking/ServerNetworking.Resync.spec.luau` |
| Atomic replacement values/domain set; stable view/subscriptions; jumping revision; Baseline source; no historical events (§29–32A) | `client/ActorView.Replacement.spec.luau` |
| Actual N4 Owner visibility loss/gain invalidates private DomainViews (§32A) | `server/Networking/Resync.ActorViews.Integration.spec.luau` |
| Malformed replacement keeps previous values/visibility/revision and cannot create an immediate retry loop (§33) | `client/ActorView.Replacement.spec.luau` |
| N4 Model seam; initial binding; stream-out/rebind; Model index; duplicate markers and collisions (§34–36) | `client/ActorView.Creation.spec.luau`, `client/ActorView.Lifecycle.spec.luau` |
| Live/recovering/incomplete removal; stale handles/references; owned Signal cleanup; distinct respawn identity (§37–39) | `client/ActorView.Lifecycle.spec.luau` |
| Default Client.Init constructs N5 before READY; immediate ACK-following traffic; later baselines; startup failure/reset cleanup (§40–41) | `client/Client.Init.ActorViews.spec.luau` |
| Unknown/invisible domain, undeclared event, invalid patch/event and initial baseline faults (§42–44) | `client/ActorView.Creation.spec.luau`, `client/ActorView.Commits.spec.luau` |
| Event-driven idle behavior; forty-eight Actors; touched-domain application; shared subtrees and lookup correctness (§46–48) | `client/ActorView.Work.spec.luau`, `client/ActorView.State.spec.luau`, `client/ActorStatePlan.spec.luau` |
| N3 → N4 → N5 discontinuity → real server admission → N4 replacement → same N5 view | `server/Networking/Resync.ActorViews.Integration.spec.luau` |
| Native two-client readiness, automatic creation, live state/events, real resync, Owner privacy and teardown | `integration/ActorViews/Server.server.luau`, `integration/ActorViews/Client.client.luau` |

## Fixtures and boundaries

- `client/Utils/ActorViewTestUtils.luau` compiles a real N1/N2 custom-domain
  manifest and feeds buffer-backed baselines/commits through the real N4 codec
  and ActorStreamRuntime. Model tests emit N4 discovery events. N5 performs no
  fixture-owned state application or revision bookkeeping.
- The custom domains cover scalar truth, an Optional Owner-only value and a
  Stamina Struct with nested Struct/Map/Array/Optional values. Semantic events
  include composite, zero, false and Optional nil payloads. Visible domain
  presence is distinct from a visible domain whose current value is nil.
- Invalid decoded values are delivered directly to N5's private consumer so its
  all-or-nothing validation can be tested independently of N4's wire validation.
  Existing `shared/Networking/ActorStreamCodec.Hardening.spec.luau` and N4 assembly
  tests retain responsibility for invalid numeric codes, framing and generations.
- `client/Networking/utils/ActorStatePlan` is a private compiled schema application seam. `Snapshot` and
  `Apply` return `{ value = ... }` on success so a successful Optional nil result
  cannot be confused with failure. Safe ownership transfer and copying are both
  allowed; mutable aliases into published truth are forbidden.
- Private `_InspectForTests` diagnostics expose applied revision, stream status
  and buffered incremental count. These are not members of any public ActorView,
  DomainView or ActorViewRegistry. Revision checks also infer successful progress
  by applying the next real record after event-only work and replacement.
- Fire-order tests observe the existing GoodSignal `Fire` boundary and snapshot
  current state/revision there. They do not infer dispatch order from arbitrary
  consumer callback scheduling. Yielding-handler tests retain historical event
  payloads and deliberately resume after later authoritative state arrives.
- Public event handlers collect observations; contract assertions run in the
  test body. The throwing-consumer case deliberately exercises KRF's real Signal
  error isolation. Fixtures disconnect subscriptions, cancel blocked consumers
  and restore patched factories/Signal methods after each test.
- Server admission uses injected clocks and small hard windows. N4 remains the
  owner of awareness/removal/pending-baseline validation. Rate-limited traffic
  cannot reach replacement capture; unknown-handle floods cannot create
  unbounded capture work. Closed releases session accounting.
- Production startup tests keep the native installers and receive routing intact;
  they replace platform transport/discovery/clock/scheduling adapters and observe
  runtime factories. No game-side `Consumer.Install` call initializes N5.
- The full recovery integration keeps real N3 capture, N4 recipient selection,
  revision allocation, codec, assembly and replacement machinery. It drops one
  complete live commit deliberately, then observes recovery through N5's request.
  A separate integration exercises actual N4 Owner reassociation.
- N4 `ActorHalt` is terminal, as required by `client/Networking/types.ActorStreamConsumer`: it
  invalidates queryable authoritative truth and stops resync while identity and
  Model lifecycle continue until authoritative removal. It is distinct from
  recoverable desync, which retains last good truth.

## Private implementation choices established by the tests

- Public module: `client/Actor/ActorViewRegistry`; types: `client/Actor/types`.
- The frozen registry delegates lookup to `client/Actor/utils/ActorViewRegistryState`.
  Only that private owner exposes installation, removal and writable lifecycle
  Signals. Public lookup methods are `read` and public events remain wrapped.
- `client/Actor/ActorView` owns identity, Model, visible DomainViews and Actor-level
  events. `client/Actor/DomainView` owns immutable state, change/semantic events
  and teardown. Their typed constructors create private owners and frozen public views.
  Private owners separate installation from notification so Networking can stage
  all state and indexes before firing events. `ActorViewRuntime` owns N4 callbacks,
  revision validation, recovery coordination and atomic publication;
  `ActorStatePlan` owns schema-aware immutable snapshot/patch operations.
- Internal Networking contracts are consolidated in one `types.luau` per side.
  Primary runtimes remain at the system root; implementation collaborators,
  platform adapters and lifecycle bridges live in lowercase `utils/`. Source
  moves do not change the spec names in the contract map above.
- The private runtime consumes the existing N4 `Consumer` callback shape.
- Changed-domain Fire order is domain-id order; semantic Fire order remains the
  supplied authoritative order. No event-id sorting is permitted.
- Retired DomainViews expose no old state. Strict destroyed-object errors or nil
  are both accepted for state queries; their owned events must reject new
  subscriptions. Reappearance creates a new DomainView.
- Stable private errors: `InvalidActorState`, `InvalidActorPatch`,
  `InvalidActorHandle`, `MalformedResyncRequest`, `ResyncRateLimited`, and
  `ResyncRuntimeDestroyed`. N4 admission failures retain their existing reasons.
- Resync wire byte layout and default traffic thresholds remain private. Tests
  round-trip the codec and inject window limits rather than prescribe opcodes.

## Validation and performance review

Use the repository commands from its root:

```powershell
npm run test:unit
npm test
npm run test:integration:n5
```

The native command builds `n5-actor-view-test.project.json` and uses Studio's
documented `RunScript` CLI task to execute the Edit-DataModel launcher
`scripts/run-n5-actor-view-tests.luau`. The launcher calls
`StudioTestService:ExecuteMultiplayerTestAsync(2, ...)`. Studio must be installed;
no MCP server or temporary local plugin is required. To select a Studio executable,
invoke `scripts/test-n5-native.ps1 -StudioPath <absolute-path>` directly.
Each invocation retains its place and logs under ignored `build/n5-native/<run-id>`.
Exit 0 requires a real success result, exit 1 is a reported contract failure, and
exit 2 indicates no verified result (for example, a launcher timeout).

Both clients call normal `Client.Init` with production consumer installation.
The server observes real factories and injects one discontinuous, valid Commit
through the framework Reliable transport; it never simulates a recovery request
or replacement callback. Recovery must use the real client-to-server buffer path
and server admission, retain view identity, restore current truth and avoid event
replay. Both clients verify private Owner visibility, stale private view
invalidation, authoritative removal, distinct respawn and reset with a live view.
Real Character reassignment removes the old engine Model, so the fixture retires
its Actor before respawn; it does not try to preserve an Actor whose Model was
destroyed. Same-Actor Owner loss/gain remains covered by the N3/N4/N5 integration
suite. The orchestration
RemoteEvent carries only test phases/reports, never Actor state delivery.

On the pulled main baseline, `npm run test:unit` passed **126 suites / 1,597
tests**, including the existing coverage checks. The N5 contract suite must remain
red until implementation. Missing behavior should appear as assertion failures,
`N5NotImplemented` results, or explicit assertions that a valid baseline must
publish a view; there should be no missing-module/member, syntax, fixture schema
or type errors. Existing suites must remain green. Coverage thresholds, test
selection and the standard runner are unchanged.

Final red-phase validation on 2026-10-17: `npm test` passed formatting/lint
with zero errors or warnings and passed Luau type checking. Jest reported
**126 existing suites passing, 14 N5 suites failing; 1,598 tests passing and
163 failing, 1,761 total**. Of the 164 new tests, the incomplete-removal
non-publication guard already passes; the remaining 163 fail on unimplemented
N5 behavior. No new tests are skipped. The full command exits nonzero as expected;
the chained coverage threshold step therefore does not run on the red suite.

Audit follow-up validation on 2026-10-17 adds 11 passing registry immutability
regressions and three red private ownership contracts. The suite now reports
**127 passing suites / 15 failing suites; 1,609 passing tests / 166 failing tests,
1,775 total**. Formatting/lint and Luau type checking pass. All original passing
tests remain green. The N3 PublicationRuntime and PublicationScheduler now use
real typed internal state and receivers without changing their behavior.

The native two-client command was also executed on installed Studio. Both clients
reached readiness; the run failed in `Initial` with
`Complete native baseline did not automatically create an ActorView`, as expected
before N5 implementation. Later live/recovery/privacy/teardown phases are present
but remain unexecuted behind that first missing behavior; they must pass on the
implementation branch before N5 can be considered complete.

The work tests count real schema-plan calls, verify reuse of unchanged snapshots
and subtrees, exercise forty-eight Actors and assert no idle/recovery state work.
They deliberately avoid wall-clock performance thresholds. When implementing,
also inspect the actual actorId/Model indexes and event subscriptions: black-box
lookup correctness and idle-work counters alone cannot prove asymptotic lookup
complexity or the absence of every possible empty per-frame scan. The implementation
must satisfy those architectural requirements as well as the executable tests.

## Implementation validation

The implementation adds behavioral regression cases for reentrant private-owner
teardown, registry collisions, malformed decoded containers, invalid initial
revisions, stale lifecycle callbacks, equal composite replacements, Map no-ops
and framed zero-handle recovery requests. The suite reports **144 suites / 1,786
tests passing**, with all per-file coverage thresholds unchanged and satisfied.
Latest measured coverage: **98.64% statements/lines, 96.56% branches, 99.28% functions**.

The original red suite masked several fixture errors. Assertions now pass only
the success value from `pcall` to Jest. Duplicate ActorRemove traffic explicitly
asserts N4's existing `RetiredActorHandle` rejection before checking N5's single
removal lifecycle. The throwing-consumer case retains the real Signal runner and
captures its expected errors at the host task boundary; native scheduling remains
in the yielding-consumer cases. No assertions or tests were removed or skipped.

The native two-client test now passes through `Reset`, with one accepted real
resync request after fault injection. Both clients use production startup,
decoding, view installation and Reliable delivery. Client reset is checked while
a respawned ActorView is still live, including invalidation of held private state.
The new control record increments the private protocol version to 4 so older
builds that cannot process recovery cannot complete a compatible handshake.

Consumer documentation is in `docs-site/docs/documentation/Networking/actor-views.md`
and the ActorViewRegistry, ActorView and DomainView API pages. Startup, replication
domain and Actor lifecycle guides describe the installed runtime.
