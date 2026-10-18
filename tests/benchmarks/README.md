# Running benchmarks

Run from the repository root on Windows with the pinned Rokit tools, installed
dependencies and Roblox Studio. Run Studio jobs serially, including unit tests.
The launchers print an ignored `build/<suite>/<run-id>/` directory containing
`result.json`, logs, environment metadata and any prepared place/workload files.
Keep all generated observations, reports, coverage and diagnostics under `build/`.
Do not commit individual run outputs or machine manifests.

| Command | Workload and boundary |
| --- | --- |
| `npm run measure:networking` | Deterministic ordinary/heavy/AoE traces at 30/75/90 Actors, using real publication, scheduling and codec paths with injected recipient identities and a serialized-buffer sink. Tags-only and synthetic future-domain profiles remain distinct. |
| `npm run test:integration:networking-baseline` | The same activity shapes through normal server/client startup and real transports, with two native clients and delivery/privacy/teardown assertions. |
| `npm run test:integration:tags-load` | Separate native two-client Tags test at 25/50/100 Actors, paced and burst mutations. See [TagsLoad.md](./TagsLoad.md). |
| `npm run measure:tags` | Separate extreme single-Actor Tag-map scaling test. See [TagsPublication.md](./TagsPublication.md). |

The realistic traces model 10/25/30 players and 20/50/60 NPCs. Tags have small
active maps and varying stacks; only a subset fights. Synthetic game-defined
domains model 20 or 40 active Actions **across the lobby** and six Resource-shaped
entries per Actor. They exercise generic replication, not built-in future adapters.
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
