# Running benchmarks

Run from the repository root on Windows with the pinned Rokit tools, installed
dependencies and Roblox Studio. Run Studio jobs serially, including unit tests.
The launchers print an ignored `build/<suite>/<run-id>/` directory containing
`result.json`, logs, environment metadata and any prepared place/workload files.
Keep all generated observations, reports, coverage and diagnostics under `build/`.
Do not commit individual run outputs or machine manifests.

| Command | Workload and boundary |
| --- | --- |
| `npm run measure:networking` | Deterministic ordinary/heavy/AoE traces at 30/75/90 Actors, using real publication, scheduling and codec paths with injected recipient identities and a serialized-buffer sink. Tags-only and synthetic domain profiles remain distinct. |
| `npm run measure:networking-audit` | 1/16/64/128 Actors × 1/8/32 injected recipients; idle, hot Actor, state and event pressure; isolated command/resync/recovery load and queue/coalescing experiments. |
| `npm run test:integration:networking-baseline` | The same activity shapes through normal server/client startup and real transports, with 2 native clients by default (2/4/6/8 supported) and delivery/privacy/teardown assertions on every client. |
| `npm run measure:n4` | Sustained generic load at 75/90 Actors and 2/10/25/30 injected recipients: 30 seconds heavy, 15 seconds light, 75 seconds quiet recovery with ongoing sentinel traffic. Queue bounds, fairness, explicit replacement baselines and current truth are asserted. |
| `npm run test:integration:n4-performance` | The original native server/client fixture with a Scenario wrapper selecting 75/90 Actors and 45 seconds of heavy Tags traffic; two native clients. |
| `npm run test:integration:tags-load` | Separate native two-client Tags test at 25/50/100 Actors, paced and burst mutations. See [TagsLoad.md](./TagsLoad.md). |
| `npm run measure:tags` | Separate extreme single-Actor Tag-map scaling test. See [TagsPublication.md](./TagsPublication.md). |
| `powershell -ExecutionPolicy Bypass -File scripts/measure-networking-baseline.ps1 -Workload Observers` | Private mutation callback costs plus real regeneration, Tag/Property churn and Action Start/End transactions through normal server startup and N3 at 30/75/90 Actors. |

The observer workload uses six regenerating Resources per Actor, two active Actions
per Actor at 30/75 Actors and 32 at 90 Actors. Each population runs with zero, one
and four additional private observers. Regeneration observers explicitly opt in;
built-in Resource replication excludes ordinary regeneration steps. Counts, current
authority, lifecycle publication totals and cleanup are asserted. Each row reports
120 timed batches after 10 warmup batches, normalized per Resource change, Tag
mutation or Action transition; the batch size is recorded. Yields occur outside
timing. Separate Tag rows compare resolved Property changes with mutations that
affect no Properties; the latter asserts unchanged Resource observer counts and
exact Tag publication totals. Separate Action rows include Resource costs with
owned Tags and Resource costs without Tags. The latter records additional private
Tag Commit and Dispatch callback totals across warmup and timed batches, allowing
the same fixture to measure empty-batch delivery before and after a change.
Run twice in fresh Studio processes. The empty-callback `pcall` row is an unsafe
historical reference, not an interchangeable implementation. The separate
yielding-callback row measures detection and cancellation, which normal callbacks
do not execute. Heap deltas show allocation/GC activity, not retained-memory growth.
This measures server CPU without transport recipients; native suites cover delivery.

The realistic traces model 10/25/30 players and 20/50/60 NPCs. Tags have small
active maps and varying stacks; only a subset fights. Synthetic game-defined
domains model 20 or 40 active Actions **across the lobby** and six Resource-shaped
entries per Actor. They exercise generic replication rather than the built-in
Actions/Resources adapters used by the separate observer workload.
The scenario definitions and assertions in the fixtures are the workload contract.

## Analyze local baseline runs

Run the CPU command twice and the native command three times in fresh processes.
Copy their successful `result.json` files into `build/networking-analysis/`, named
`cpu-run1.json`, `cpu-run2.json` and `native-run1.json` through `native-run3.json`.
Keep the original launcher directories for source hashes and environment metadata.
The analyzer also accepts these filenames with a `.gz` suffix.

```powershell
New-Item -ItemType Directory -Force build/networking-analysis
Copy-Item build/networking-cpu/<run-id>/result.json build/networking-analysis/cpu-run1.json
# Copy subsequent CPU/native results using the names above.
node scripts/analyze-networking-baseline.cjs build/networking-analysis > build/networking-analysis/summary.json
```

Both launchers accept `-StudioPath <absolute-path>` when invoked directly. Native
delivery supports 2/4/6/8 actual Studio clients; injected recipients measure server
CPU/fanout and serialized payloads, not native delivery at that recipient count.
Virtual scheduling opportunities are not observed frames or network latency.
Payload bytes exclude Roblox/NIC overhead. Heap samples include fixture allocations.
Quantiles use nearest rank, with p95 at 20 samples and p99 at 100; independent trial
counts still matter. Preserve correctness assertions and avoid machine timing gates.

Historical findings and methodology live in [baseline PR #90](https://github.com/KevMP/KRF/pull/90).
Optimization comparisons and architectural recommendations live in [PR #91](https://github.com/KevMP/KRF/pull/91).

## Paired processing comparisons

At each implementation, run `measure:networking` (short), `measure:n4` (sustained)
and `test:integration:n4-performance` (native) twice in fresh processes. Copy each
`result.json` into `build/n4-comparison/` using
`<before|after>-<short|sustained|native>-run<number>.json`. Gzip JSON is also accepted.

```powershell
node scripts/analyze-n4-performance.cjs build/n4-comparison > build/n4-comparison/summary.json
```

The analyzer checks deterministic delivery signatures across paired CPU trials
and reports pooled timings with per-trial totals. Keep the workloads, budgets and
probe configuration identical. Do not mix duplicate plain/gzip copies of one run.
Keep excluded pilots outside the matching filenames.

To freeze a place and its workload before editing production code:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/measure-n4-performance.ps1 -PrepareOnly
powershell -ExecutionPolicy Bypass -File scripts/measure-n4-performance.ps1 -PreparedRunDirectory <printed-directory>
```

Use `-Profile Native -PrepareOnly` to freeze the native variant. Keep the prepared
directory intact and use a separate preparation for each trial. To compare the
extended harness against the baseline PR, prepare it with only the three optimized
modules restored from the baseline branch: `ActorAwarenessRuntime.luau`,
`utils/ActorRecipientStream.luau` and `utils/PublicationScheduler.luau` under
`src/server/Networking/`. Restore the optimized modules before preparing the after
variant. This holds the sustained fixture constant without requiring historical
measurement commits or saved results. Use a clean checkout and retain source hashes.

## Networking hardening audit

### Native client-count comparisons

Keep the default two-client regression and run the same nine traces (30/75/90
Actors × Ordinary/Heavy/Burst) at each supported count in fresh processes:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/test-networking-baseline.ps1 -ClientCount 8
powershell -ExecutionPolicy Bypass -File scripts/test-networking-baseline.ps1 -ClientCount 8 -ImplementationRevision a9f1d7bcaa822e3b2ee0b6180f326bd2a95efc2a
```

Repeat with `-ClientCount 2`, `4` and `6`. The reference option archives only
production `src/` into the ignored run directory and builds it with the current
fixture, without changing the checkout. Each run freezes its place and launcher
and records their hashes, implementation/harness revisions, source hashes, Studio
version and working-tree status before launch. Keep the same harness and Studio
across comparisons; repeat trials and alternate reference/candidate order.

Copy successful results to an analysis directory using
`native-<candidate|n9>-c<count>-run<number>.json` (optionally gzip). The existing
`analyze-networking-baseline.cjs` accepts these names, validates the recorded
count and unique client identities, and separates count/implementation groups.
It rejects mixed fixture/Studio hashes and source changes within an implementation
group. Do not pool different implementations, client counts or pilot fixtures.

Server measurements include mutation, awareness-pump elapsed time, Heartbeat,
Lua heap, traffic and workload lateness. Each actual client records packet-handler
elapsed time around the real installed consumer (decode/application), Heartbeat,
RenderStepped intervals, Lua heap and mutation-to-public-notification latency.
Public listeners and validation are deferred outside the handler timing; fixture
allocation and wrapper overhead remain in the run. Inspect each client's tails,
not just pooled latency. These region timings are wall time, not OS CPU time.

The launcher samples Windows host CPU, busiest logical processor, available RAM,
commit pressure and page inputs alongside the launched Studio process tree.
Command-line `StartServer`/`StartClient` roles distinguish OS CPU consumption,
working set and private memory for server, individual clients and Edit launcher.
CPU cores equal process CPU seconds divided by elapsed seconds; divide by the
recorded logical processor count for machine utilization. Working sets can share
pages, so their sum is not unique physical memory. Page inputs include executable
and asset reads and do not by themselves prove paging due to memory exhaustion.

A two-second zero-packet quiet window at each population supplies a scene/engine
reference. Unix-millisecond case windows correlate host samples to workloads;
performance regions use monotonic clocks. Host counters target one-second
sampling, have collection lag, and cannot explain sub-frame stalls. Monitor
collection wall cost and its own process CPU are recorded; CIM-provider overhead
is part of host load. `host.json` remains available even if a test fails.

Compare active/quiet frame intervals, KRF region costs, per-process CPU and memory
headroom before attributing client-count scaling to KRF. A busy logical processor,
rendering/GPU pressure, engine scheduling or another application can limit a local
multiclient host while overall CPU remains below 100%. This harness does not
isolate GPU time, engine costs, remote-machine behavior, bandwidth-limited links
or real WAN latency. Report uncertainty rather than treating all frame delay as
framework work, and retain the original two-client correctness suites.

### Server audit

The reference implementation is final merged N9:
`a9f1d7bcaa822e3b2ee0b6180f326bd2a95efc2a`. Keep production `src/` at that
revision when measuring the reference with a newer harness. Use a separate clean
checkout for the reference, copy only the benchmark fixtures, launchers and
analysis tooling from the candidate, and verify `git diff <reference> -- src`
is empty. Record the harness revision separately from the measured implementation.

Run Studio jobs serially. Run the audit twice, the existing short CPU and sustained
CPU workloads twice each, and native Networking baseline three times, each in a
fresh process. The existing native N9 suite supplies actual command/result,
callback-ordering and teardown coverage; the audit's opaque recipients exercise
the production server runtimes without measuring native delivery at 8/32 clients.

```powershell
npm run measure:networking-audit
# Repeat in a fresh process, retaining both printed run directories.
New-Item -ItemType Directory -Force build/networking-analysis
Copy-Item build/networking-cpu/<audit-run-1>/result.json build/networking-analysis/audit-run1.json
Copy-Item build/networking-cpu/<audit-run-2>/result.json build/networking-analysis/audit-run2.json
node scripts/analyze-networking-baseline.cjs build/networking-analysis > build/networking-analysis/summary.json
```

The audit uses a discarded 16-Actor pilot, then 120 deterministic workload pumps
per scene with ascending Actor order. The generic domain has one U32 value and
8 KiB of unchanged padding, producing multipart join/recovery baselines. This is
a controlled schema fixture, not a built-in Action or Resource benchmark. A hot
scene changes one Actor per pump; state/event scenes change every Actor. Separate
passes run without probes and with benchmark-local method counters. Compare
their per-trial distributions; fixed pass order and GC can affect the difference.
These wrappers are not permanent diagnostics and do not count every internal loop.

`queueWaitPumps` samples the interval from a stream becoming pending to its next
Commit/BaselineEnd, with same-pump delivery equal to zero. It excludes unsatisfied
samples and is neither per-event latency nor wall-clock/network latency. The older
CPU fixture supplies per-commit wait distributions including its drain phase.
Pending-byte samples are logical encoded liabilities (queued record estimates,
full retained baseline bodies and reserved result bytes), not heap size or unique
buffer allocations: shared baseline bodies count once per recipient. Samples occur
before and after each pump; they are not allocation high-water instrumentation.
Inspection and decoding occur outside timed pump/mutation regions. Physical send
counts include the sink call and exclude Roblox engine/network overhead.

Recovery uses an injected eight-event limit and 16 events before each pump; it
reports capture attempts and completions during pressure, then asserts quiet drain
converges. Command scenes submit 80 requests per recipient in one fixed rate window,
without an intervening send pump. Malformed requests retain the command kind byte.
Resync scenes repeat one valid handle while replacement is pending and distinguish
accepted requests, pending dedupes and rate rejections. These are separate stress
experiments, not a proof of combined-pressure fairness or a slow native connection.

Queue experiments compare front removal with a head-cursor loop and time the
existing pending-transfer counting shape (up to 16 entries). They are algorithm
experiments, not measured runtime speedups. Result-order experiments count actual
`HasWorkThrough` calls with newer Actor work behind a result. Coalescing experiments
isolate the real publication scheduler at 16/128/512 Map entries and 0/8/64 event
barriers; each of 30 samples contains 20 writes and uses a constant 64-byte size
estimator, excluding codec cost. Timing quantiles stay per trial; the analyzer does
not average quantiles or impose machine-time gates.

Freeze each CPU trial before switching implementations:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/measure-networking-baseline.ps1 -Workload Audit -PrepareOnly
powershell -ExecutionPolicy Bypass -File scripts/measure-networking-baseline.ps1 -PreparedRunDirectory <printed-directory>
```

Preparation saves the built place, workload, source/harness hashes, dirty-file
status and environment before launch. Execution verifies the frozen place/workload
hashes. Use a separate preparation per trial and the same Studio executable.
Candidate comparisons must use identical workload versions and harness hashes.
Raw observations stay under ignored `build/`; evidence and checkpoint decisions
belong in the active PR description. Hint and combined-pressure measurements must
be added once those primitives exist; they cannot be inferred from an N9 baseline.
