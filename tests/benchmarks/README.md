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
| `npm run test:integration:networking-baseline` | The same activity shapes through normal server/client startup and real transports, with two native clients and delivery/privacy/teardown assertions. |
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
timing. Run twice in fresh Studio processes. The empty-callback `pcall` row is an
unsafe historical reference, not an interchangeable implementation. The separate
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
delivery is measured with exactly two clients; injected recipients measure server
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
