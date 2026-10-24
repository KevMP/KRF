# Running benchmarks

Run from the repository root on Windows with the pinned Rokit tools, installed
dependencies and Roblox Studio. Run Studio jobs serially, including unit tests.
The launchers print an ignored `build/<suite>/<run-id>/` directory containing
`result.json`, logs, environment metadata and any prepared place/workload files.
Keep all generated observations, reports, coverage and diagnostics under `build/`.
Do not commit individual run outputs or machine manifests.

## Compare reference and candidate

```powershell
npm run bench:networking:compare
# One short CPU pair against pinned merged N9; no native matrix by default.
npm run bench:networking:compare -- --profile native --clients 2,8 --repetitions 2
npm run bench:networking:compare -- --reference HEAD~1 --profile both --clients 8
npm run bench:networking:compare -- --workload publication --profile native --clients 2,4,6,8
npm run bench:networking:compare -- --full
# Scheduler audit and equal-configuration budget experiments:
npm run bench:networking:compare -- --workload audit --reference HEAD~1 --repetitions 2
npm run bench:networking:compare -- --workload publication --reference HEAD~1 --records 128 --bytes 65536
npm run bench:networking:compare -- --workload publication --focus scheduler --reference HEAD~1 --records 128 --bytes 32768 --repetitions 2
```

The default is the commands workload, CPU profile, one reference/candidate pair.
`--full` explicitly selects CPU plus 2/4/6/8 native clients and two repetitions.
Explicit options override those defaults. `--workload` accepts `commands` or
`publication`, or `audit` (CPU only); `--profile` accepts `cpu`, `native` or `both`; `--clients` is a
comma-separated subset of 2/4/6/8; `--repetitions` accepts 1..10. `--reference`
accepts a local Git commit/ref and defaults to merged N9
`a9f1d7bcaa822e3b2ee0b6180f326bd2a95efc2a`. Use `--studio <exe>` to select an
installed Studio explicitly. Publication CPU uses the existing short Networking
profile. Observers and sustained N4 remain independent launchers below.

`--records` (1..4096, default 64) and `--bytes` (1024..4194304, default 32768)
set fixture-only pump budgets identically in both arms. Launchers capture these
values in the built place and provenance; analysis rejects mismatched settings.
Direct launchers accept `-Records` and `-Bytes` too. No production constants or
public configuration change is needed. Keep equal-budget revision comparisons
separate from configuration experiments: changing capacity changes the work
completed per pump and can affect packetization, CPU and latency.

Use `--candidate-records <count>` to compare a proposed record default with the
reference's `--records` value. Byte capacity stays equal. This is explicitly
labelled a configuration experiment in JSON/Markdown; it cannot isolate an
implementation speedup. Omitting the option keeps equal capacities. For example,
`--records 64 --candidate-records 128 --bytes 32768` compares those service limits
with the same offered workload. Fixture defaults remain 64/32768 for historical
reproduction even when production defaults change.

For short CPU budget experiments, `--focus scheduler` selects twelve existing
publication cases: 90 Actors, 2/30 recipients, Ordinary/Heavy/Burst, 0/40 synthetic
Actions, without diagnostic wrappers. Mutation plans and case timings are
unchanged. Both arms use the same subset; provenance and all twelve identities
are verified. This option requires the publication workload and CPU profile.
The default remains the complete matrix, including 10/25/30 recipient fanout;
native 2/4/6/8 regressions always use the full native fixture.

The orchestrator resolves the reference once, chooses one Studio executable,
alternates arm order, invokes the existing launchers serially and copies their
verified results automatically. Each comparison has an ignored
`build/networking-comparisons/<timestamp-id>/` directory:

- `manifest.json`: the complete plan, statuses, revisions, hashes, log names and
  original frozen run directories.
- `raw/`: named result copies for the existing analyzers.
- `analysis-*.json`: those analyzers' full distributions and per-trial evidence.
- `comparison.json` and `comparison.md`: counts, per-client admission/execution,
  latency quantiles, queue peaks, region costs, separate server/client OS CPU,
  observed increases and measurement limits.

Failures stop the comparison with nonzero exit status and a FAILED report.
Planned trials cannot be silently dropped. Source, harness, workload, Studio,
client-count and artifact mismatches are rejected; duplicate observations are not
independent repetitions. Current uncommitted production source can be measured,
but its hashes and dirty status remain recorded and it must stay unchanged for
the entire comparison. Commit before the final checkpoint matrix for a convenient
source identity. Run other Studio jobs and heavy checks outside measured trials.

Rebuild reports without launching Studio:

```powershell
npm run bench:networking:compare -- --analyze build/networking-comparisons/<timestamp-id>
```

The report flags every observed increase in cost or p95; timings are not pass/fail
gates and do not establish causation. Compare offered, wire-transmitted, admitted
and executed work before discussing throughput. A lower cost from shedding is not
a speedup. Native OS CPU columns contain ranges of per-trial medians in logical
cores, not averaged quantiles; client cores sum all actual client processes. CPU
profiles have region timings and virtual waits, without native OS-process samples.
Publication has no command admission count or pending-command queue metric.
Raw frames, heaps, host memory and remaining probes stay in the analysis records.
Scheduler reports retain pump p50/p95/p99 and physical sends. Current runtimes
also expose private attempted-work samples to the fixture after each timed Step;
older revisions without those counters are marked unavailable, not zero.
Audit probe passes count legacy eligibility/preparation calls separately from
unwrapped timing passes. Audit pending inspections and packet decoding happen
outside pump timers. Sample allocation/retention still affects the process heap
and GC; compare raw controls and do not attribute host CPU entirely to KRF.

## Command dispatch comparisons

Use the same offered request plan on both implementations. CPU profiles use
128 Model-backed Actors and 2/8/32 opaque recipients, production command and
publication runtimes, real result reservations and encoded-buffer egress. Native
profiles use 2/4/6/8 actual clients, normal startup and public command sends that
mutate owned Tags. Requester result callbacks must precede their state callbacks;
every executed command must produce exactly one state change, semantic event and
correlated result. Native retirement/reset uses the installed consumers.

```powershell
powershell -ExecutionPolicy Bypass -File scripts/measure-networking-baseline.ps1 -Workload Commands
powershell -ExecutionPolicy Bypass -File scripts/measure-networking-baseline.ps1 -Workload Commands -ImplementationRevision a9f1d7bcaa822e3b2ee0b6180f326bd2a95efc2a
powershell -ExecutionPolicy Bypass -File scripts/test-networking-baseline.ps1 -Workload Commands -ClientCount 8
powershell -ExecutionPolicy Bypass -File scripts/test-networking-baseline.ps1 -Workload Commands -ClientCount 8 -ImplementationRevision a9f1d7bcaa822e3b2ee0b6180f326bd2a95efc2a
```

Repeat CPU trials twice and native trials twice at each count, serially in fresh
processes, alternating reference/candidate order. The reference option builds
archived production source with the current fixture without changing the checkout.
Use the same Studio executable and retain source/harness hashes. The default
native publication workload remains available without `-Workload Commands`.

The shared plan offers 180 ticks at 30 Hz: Sustained sends one request every
second tick per client; Uneven sends three every second tick for the hot client,
one every sixth tick for middle clients, and four once per second for the last,
intermittent client. Overload sends 80 requests per client in the first tick.
Workload v2 adds Late (64/noisy client before eight quiet-client requests, then
two quiet requests/sec) and Pressure (eight/noisy client every fourth tick;
five quiet requests in the last fifth of each second). CPU Late submits complete
noisy bursts before the quiet client without an intervening pump; other CPU
plans retain interleaved identity order. Native Late delays the quiet first burst
by 1 ms; transport/engine scheduling can change actual arrival order. All native
clients otherwise pace against the same server epoch. CPU dispatch/outbound pumps occur twice per tick;
their waits are virtual pump counts, not native frames or latency. A discarded
CPU warmup uses the same handlers; native startup includes a quiet settling period.
Native Overload/Late are followed by a 21-second quiet interval outside timed
windows, allowing timeout/grace metadata to expire before the next offered plan.
Both arms use that interval even if one refused less work. CPU cases instead own
fresh independent runtimes. Native offered counts include public Send calls;
wire counts and local refusals remain separate. Per-window admission counts use
server ingress time. Small native counts may not exhaust the aggregate attempt
budget because existing per-client rate limits also apply; 32-recipient CPU
Pressure supplies that controlled experiment, without claiming 32 native clients.

For individual launches or importing older evidence, copy successful results into `build/command-comparison/` with names
`<before|after>-cpu-run<number>.json` or
`<before|after>-native-c<2|4|6|8>-run<number>.json`. Gzip JSON is accepted.

```powershell
node scripts/analyze-command-dispatch.cjs build/command-comparison > build/command-comparison/summary.json
# An optional final argument supplies a different resolved reference SHA.
```

The analyzer validates pinned reference provenance, matching fixture/Studio
versions, stable source within each arm, workload/count completeness, actual native
client process witnesses and unique client identities. It rejects duplicate
plain/gzip observations and checks the candidate's default job/byte/dispatch/visit
bounds. Workload v1 inputs remain readable, but may not be mixed with v2 in one
comparison. Retain per-trial results alongside pooled raw timing distributions.

Record offered requests, local refusals, private runtime admission, authoritative
execution, pre-effect unexecuted requests, admission reasons, blocked reservations,
pending jobs/bytes, result reservations and per-client progress separately. The
reference private `Handle` can return true yet execute no handler if result
capacity is full; the queued dispatcher defers that head before effects instead.
Neither path invents a definitive rejection. Latencies conditional on completed
requests must not disguise shed work or be advertised as throughput gains.

Server region timers measure elapsed wall time, including probe/fixture overhead;
the native launcher separately samples OS CPU/memory. Client result latency is
measured from public Send to its correlated callback on the same client clock.
Eligibility-gap probes count other handlers while an admitted FIFO head has
result capacity; blocked heads are excluded and reported separately. This probe
inspects private runtime state and adds fixture overhead. Heap samples include
verification allocations. The CPU fixture also creates publication/egress pressure;
it is not an isolated handler microbenchmark. Native counts above eight, WAN and
slow-device behavior are not supplied. Use the existing publication and built-in
command regressions alongside these profiles; keep results/limitations in the PR.

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

Choose the desired local reference with `--reference`; merged N9 remains the
default compatibility reference. The launcher archives reference production
source and builds it with the current harness without changing the checkout.
Both source and harness identities are verified independently.

Run Studio jobs serially. Run the audit twice, the existing short CPU and sustained
CPU workloads twice each, and native Networking baseline three times, each in a
fresh process. The existing native N9 suite supplies actual command/result,
callback-ordering and teardown coverage; the audit's opaque recipients exercise
the production server runtimes without measuring native delivery at 8/32 clients.

```powershell
npm run bench:networking:compare -- --workload audit --reference HEAD~1 --repetitions 2
```

The audit uses a discarded 16-Actor pilot, then 120 deterministic workload pumps
per scene with ascending Actor order. The generic domain has one U32 value and
8 KiB of unchanged padding, producing multipart join/recovery baselines. This is
a controlled schema fixture, not a built-in Action or Resource benchmark. A hot
scene changes one Actor per pump; state/event scenes change every Actor. HotQuiet
emits one event from Actor 1 every pump and events from every other Actor once
per 30 pumps, retaining offered/completed counts per Actor and asserting every
quiet Actor makes progress during pressure. Separate
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
reports capture attempts, successful generations per recipient and completions
during pressure, asserts every recipient gets a capture opportunity, then asserts
quiet drain converges. Fewer replacement attempts can reflect deferral rather
than more completed work. Command scenes submit 80 requests per recipient in one fixed rate window,
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
