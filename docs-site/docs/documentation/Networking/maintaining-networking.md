---
sidebar_position: 6
---

# Maintaining Networking

This maintainer reference explains bounded scheduling, retained ownership and local diagnostics. Games normally use [domains](./replication-domains), [commands](./commands) and [Hints](./hints); the limits and introspection below are private implementation policy.

## Scheduler and budgets

Reliable work uses active connection/Actor queues. Idle Heartbeats do not traverse every Ready client × aware Actor. Registration, joins, retirement and relevant mutations may visit affected relationships; active-set scheduling does not make those lifecycle operations constant-time.

| Bound | Meaning |
| --- | --- |
| Global retained records/bytes | Admission includes all recipients and held baseline anchors, not just this pump's output |
| Recipient and Actor retained records/bytes | A single backlog cannot consume the entire shared ledger |
| Stream barriers/events/bytes | Preserve ordered history only while it fits; overflow enters recipient/Actor discontinuity |
| Pump bytes/records/sends | Bound complete delivery and packet construction, including multipart baseline work |
| Attempted work | Bound connection/stream visits, eligibility checks, preparation, size measurement, encoding, expensive capture claims and priority inspections even when no send results |
| Commands | Separate attempt/byte, pending/in-progress, dispatch and output-reservation bounds |
| Hints | Separate disposable rate, packet/record, live-key, pending-byte and dispatch bounds |

Continuously eligible connections and streams receive turns; hot publication cannot permanently starve eligible joining/recovery work, or vice versa. An unavailable target, exhausted budget or causal fence can make work ineligible. Fairness is progress under those constraints, not equal byte shares, a fixed replication frequency or a wall-clock deadline. Arbitrary game callback CPU and Roblox engine scheduling are outside the work-unit bound.

Packet assembly batches compatible Actor records across streams within the existing envelope. One mutation need not cause one physical send. Command results remain separately framed on the same reliable RemoteEvent: mixed Actor/result buffers are not required. Every record is revalidated before encoding and settled after send, so reentrant closure/replacement cannot commit stale generations. Work staged across a callback keeps its ledger ownership until pump unwind; teardown does not prematurely free or double-release that capacity.

## Capture, pressure and recovery

Canonical domain state/events are synchronously schema-owned at publication. Awareness, resync and association boundaries anchor that immutable truth and sequence fence before deferred recipient projection/encoding. Post-fence commits remain after the baseline; projection cannot substitute future mutable truth. Shared bodies reuse that exact anchor and audience; ordinary preparation/delivery budgets still apply.

| Pressure class | Permitted response |
| --- | --- |
| Replaceable unsent state | Coalesce toward current truth without crossing event barriers |
| Required semantic events | Preserve continuity, or explicitly discard obsolete incremental history and require replacement for that recipient/Actor |
| Baseline/recovery | Refuse temporary capacity before retaining ownership; retry with capped backoff and bounded expensive capture work |
| Control/results | Preserve logical position and reserved output capacity; never evict to preserve disposable Hints |
| Command ingress | Defer/refuse before authoritative effects; arbitrary spam need not receive one rejection each |
| Latest/Pulse | Coalesce/refuse/drop; no reliable resync or authoritative state change |

Discontinuous streams retain bounded recovery intent rather than hidden incremental history. Replacement attempts use capped exponentially increasing **pump** delays when invalidated/refused; client resync uses its separate [timed recovery budget](./actor-views#initial-state-and-recovery). Resync requests are locally rate-limited and deduplicated before expensive work; captures share global scheduling. Persistent pressure may prevent completion. Oversized visible baselines fault as `ActorBaselineTooLarge`, rather than retrying permanent size invalidity as temporary capacity pressure.

Retirement cancels queued history, anchors, retry state and disposable Actor work before reliable removal. Disconnect/re-Ready creates a fresh connection lifetime. Warning suppression and diagnostic observation do not control these transitions.

## Command compatibility

The established command contract includes per-requester FIFO, prior-outcome history, pre-effect output reservation, result-first requester callbacks and timeout/Unknown handling. Global protected admission and bounded fair dispatch extend that contract; they do not create a second result queue or change request ids.

The requester result follows older causally ordered baseline/publication work and precedes synchronous Actor effects caused by its handler, including effects on other Actors. Backoff and multipart replacement retain the earliest logical position, so a newer result cannot jump a delayed older baseline. Other recipients retain their normal streams. Deferred game tasks are outside the handler's causal scope. Unknown means effects may have happened; a client timeout does not cancel execution. See [command ordering and uncertainty](./commands#ordering-and-uncertainty).

## Local diagnostics {#local-diagnostics}

These are framework-private, local, read-only snapshots; they are not replicated state or a stable consumer tuning API:

| Owning module | Method and result |
| --- | --- |
| `server.Networking.NetworkingDiagnostics` | `GetServerSnapshot() -> DiagnosticSnapshot?` |
| Same server module | `GetConnectionSnapshot(player: Player) -> DiagnosticSnapshot?` |
| `client.Networking.NetworkingDiagnostics` | `GetClientSnapshot() -> DiagnosticSnapshot?` |

The shared Networking types define `DiagnosticSnapshot`. Reads return nil outside the owning runtime/session; querying an absent/closed connection does not create one. Each snapshot is recursively frozen numeric data with `scope` (`Server`, `Connection`, `Client`), `counters`, `gauges`, `maxima` and `ages`. It retains no Player, Actor, packet or request history. Server aggregates survive connection closure within that server lifetime; the old per-connection snapshot is no longer queryable. Held snapshots remain historical values and do not update.

| Group | Interpretation |
| --- | --- |
| `counters` | Cumulative within the owning lifetime; observations may overlap rather than partition all traffic |
| `gauges[name].current` | Ownership now, including staged work until its owner releases it |
| `gauges[name].highWater` | Peak observed ownership in that lifetime; draining does not reset it |
| `maxima` | Largest observed pump work or local queue residence, not a percentile |
| `ages` | On-demand current oldest eligible queue age in seconds; absent when no matching work exists |

Counters/gauges update cheaply without automatic snapshots or per-packet strings. Explicit age reads can inspect bounded live queues; avoid sampling snapshots on every frame. Snapshot construction allocates, and cumulative/high-water values can include earlier scenes in a shared session.

### Metric meanings

- `reliableSendAttempts` / `unreliableSendAttempts` count transport calls, not delivery acknowledgements. `*EncodedBytes` count complete KRF encoded payloads submitted to those calls; they exclude Roblox framing/compression and are not wire bandwidth. `*LogicalRecords` measure framed records separately from physical sends.
- `publicationAdmitted`, `publicationDropped`, `stateCoalesces`, `semanticBarriers` and `streamDiscontinuities` describe publication outcomes. They are not equivalent to game mutation counts. `baselinesCaptured` counts admitted recipient generations; `baselinesCompleted` counts completed server transfers, not client acknowledgement. `baselinesRestarted`/`baselinesAbandoned`, `baselineCapacityRefusals` and `recoveryBackoffs`/`recoveryAbandoned` separate generation and retry outcomes. `reliableCaptures` measures expensive scheduler claims; shared materialization need not claim once per recipient.
- `resyncRequests`, `resyncAdmitted`, `resyncDeduplicated`, `resyncRateLimited` and `resyncRefused` distinguish requests from successful replacement work. A deduplicated request is not another baseline capture.
- `commandsReceived` counts ingress observations, `commandsAdmitted` queued requests, `commandsDispatched` selected jobs and `commandsExecuted` actual author-handler calls after authorization. Accepted/Rejected are server outcomes, not proof of receipt. `commandsFaulted` and `commandsUncertain` can both describe one request; they are not additive exclusive categories. Refused/rate-limited/abandoned work need not execute. Client `commandResultsReceived` is separate.
- `commandResultSlots` / `commandResultReservedBytes` include outstanding maximum-size reservations, not just filled results. Pending request/history/fenced-publication gauges have separate ownership. No result/history count is durable gameplay state.
- `hintsSent` means records submitted through a completed local unreliable send, not received remotely. `hintsReceived` counts validated eligible records reaching consumer dispatch (after C2S authorization and Latest stale checks). It does not certify callback success. Coalesced, dropped, stale-dropped, malformed, unauthorized and callback/send-fault counters describe distinct stages; some overlap. Packet admission is not record dispatch.
- `reliableConnectionVisits`, `reliableStreamVisits`, `reliableChecks`, prepares/measurements/encodes, priority visits and the command/Hint visit counters include attempted work, even when unproductive. `*PumpWorkUnits` maxima are private composite counts, not CPU time. Do not add overlapping counters to invent a universal work total.
- `*QueueResidenceSeconds` maxima and `ages` use a local clock and KRF eligibility/queue ownership. They are not RTT, end-to-end notification latency or a p50/p95/p99 distribution.

`reliableRecords`, `reliableRetainedBytes` and `reliableDeliveryBytes` describe different ledger liabilities: retained shared payload weight differs from per-recipient delivery liability. Publication queue, active connection/stream, baseline generation, recovery, command and Hint gauges expose their respective owners. They are not an allocation profiler, whole Luau heap size or OS process memory. Quiet queues can be zero while live Actor relationships remain; after complete teardown, tracked current ownership returns to zero while high-water/counters remain historical in already-held snapshots.

Repeated warnings use bounded category/window suppression, preserve an initial actionable occurrence, and may report suppressed counts on a later permitted warning. Terminal faults retain their failure behavior. Logging sinks cannot suspend or throw through authoritative execution. Quiet windows do not run an idle summary task, and suppressed output does not suppress semantic diagnostic counters. There is no retained closed-Actor/Player log history.

## Internal policy and measurement

The `ActorProtocolConstants`, `CommandConstants`, `HintConstants` and `DiagnosticConstants` families own units/scopes for scheduling, backlog, recovery, command reservations/admission, disposable traffic and warning policy. Tests inject small private limits through existing constructors. Games have no supported network-Hz, packet-budget, retry or diagnostic-suppression configuration table. Changing defaults requires equivalent-workload evidence and invariant tests, not exposing new knobs.

Use the [benchmark methodology](https://github.com/KevMP/KRF/blob/main/tests/benchmarks/README.md) for pinned reference revisions, equivalent fixtures, alternating trials, provenance checks and uncertainty reporting. Native clients supplement simulated recipients; machine timing remains outside structural CI. The [memory soak workflow](https://github.com/KevMP/KRF/blob/main/tests/integration/NetworkingBaseline/README.md) compares equivalent quiet phases, ownership and process readings without forced collection. Neither bounded diagnostic bytes nor stable Luau heaps prove native memory is leak-free. Retain unresolved process-memory drift as inconclusive rather than attributing it to harmless caching without evidence.

## Related

- [Actor replication and overload example](./actor-replication#state-coalescing-and-event-overload)
- [Command results and uncertainty](./commands)
- [Disposable Hints](./hints)
- [Networking startup](./startup)
