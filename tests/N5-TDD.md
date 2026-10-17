# N5 contract suite

Source: [issue #75](https://github.com/KevMP/KRF/issues/75), grounded in the KRF
charter and the implemented N1–N4 schema, bootstrap, publication and Actor-stream
contracts. This commit is the **red phase**. It adds loadable, typed placeholders
and executable tests; it does not apply Actor state, publish ActorViews, install
N5 during startup, encode resync requests or implement server recovery admission.

## Contract map

All paths below are relative to `tests/`. The section numbers refer to issue #75.

| Ticket contract | Specifications |
| --- | --- |
| Public ActorView/DomainView/registry shape; no wire or future typed API (§1–6, 23) | `client/ActorView.Creation.spec.luau`, `client/ActorView.State.spec.luau` |
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
```

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

The work tests count real schema-plan calls, verify reuse of unchanged snapshots
and subtrees, exercise forty-eight Actors and assert no idle/recovery state work.
They deliberately avoid wall-clock performance thresholds. When implementing,
also inspect the actual actorId/Model indexes and event subscriptions: black-box
lookup correctness and idle-work counters alone cannot prove asymptotic lookup
complexity or the absence of every possible empty per-frame scan. The implementation
must satisfy those architectural requirements as well as the executable tests.

Consumer documentation from the ticket belongs with the implementation. This
red-phase test map does not advertise unimplemented APIs as usable functionality.
