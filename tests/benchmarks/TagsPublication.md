# Tags publication scaling measurement

Issue: [#76](https://github.com/KevMP/KRF/issues/76). Measured on 2026-10-18 against implementation commit `64144f3`, with the accompanying benchmark additions. No production code changed for this measurement.

## Reproduce

Run `npm run measure:tags` from the repository root on Windows with the repository's Roblox Studio, Rojo and run-in-roblox tooling installed. Run Studio jobs serially: run-in-roblox temporarily installs a shared plugin. Results and launcher logs are written under `build/tags-scaling/<run-id>/`.

The standalone [benchmark](./TagsPublication.luau) runs in real Studio, without Jest or coverage instrumentation. Its timings include synchronous `TagController:AddTag` work through the selected observation boundary. One Actor has **1, 16, 64, 256, 1,024 or 4,096 distinct visible Tag IDs simultaneously active**, with one finite instance per ID. Each refresh touches only `Scale.Tag0001`, alternates its duration between 60 and 61 seconds, and uses the production synchronized clock. Automatic stepping is disabled to isolate mutation cost; no countdown work is timed.

For each size, three separate controller lifetimes measure:

- `Controller`: authoritative mutation with no replication observer.
- `Projection`: controller mutation plus the real adapter's synchronous aggregate update, with a counting callback. This deliberately excludes the adapter's full-map snapshot clone and all N3 work; it is **not** the complete adapter/publication path.
- `Publication`: controller mutation, adapter update and snapshot clone, then ordinary N3 event validation, canonical capture/diff, full-state measurement and commit observation. No publication stages are bypassed.

Static catalog/schema compilation, initial seeding/attachment and teardown are outside timing. Each mode/size has 32 warmups and three trials of 200 individually timed refreshes, yielding outside the timed interval every 20 samples. Each process therefore records 600 samples per mode/size. GC and scheduling variation can affect tails; elapsed microseconds are observations, not CI thresholds.

There are no N4 recipients, packet encoding/delivery or N5 client callbacks in these CPU measurements. They do not measure FPS, network latency, bandwidth, concurrent Actors, multi-domain transactions or large instance stacks. The separate native two-client fixture verifies actual startup, transports and consumer installation. Its initial baseline had two visible IDs and one private ID active, four instances total. Its authoritative mutation batch briefly reached five instances before removing one stack; clients received the final aggregate. It was not a scaling test.

## Results

Two fresh Studio processes on Windows, Intel Core i9-9900K @ 3.60 GHz; configured Studio file version `0, 743, 0, 7431133`. Each table entry below summarizes 600 samples in its process. Keep the [first](./results/tags-publication-2026-10-18-run1.json) and [second](./results/tags-publication-2026-10-18-run2.json) recorded results for trial medians, means, maxima and diagnostic counters.

| Simultaneously active visible IDs | Full publication median, run 1 (ms) | Full publication median, run 2 (ms) | Full publication p95, run 2 (ms) |
| ---: | ---: | ---: | ---: |
| 1 | 0.0125 | 0.0122 | 0.0340 |
| 16 | 0.0308 | 0.0290 | 0.0658 |
| 64 | 0.0955 | 0.0926 | 0.1409 |
| 256 | 0.3537 | 0.3553 | 0.4215 |
| 1,024 | 1.3344 | 1.3412 | 1.5564 |
| 4,096 | 5.5729 | 5.6398 | 6.6334 |

Controller-only medians were 1.1–1.3 microseconds. Projection-update medians were 2.4–2.7 microseconds across both runs and all sizes. The complete publication path grows approximately with the active visible map, even though the aggregate update and resulting patch remain small. These desktop observations do not establish a production server budget.

## Work, measured separately from latency

An untimed pass wraps the real schema validator and compiled codec, delegates all work to them, and records one refresh after attachment. These wrappers are absent during all timing samples and are restored afterward. They count numeric/Enum validation calls and the number of canonical map entries supplied to the real full-state `Measure`, not all internal codec operations or allocations.

Both processes produced the same counts:

| Active IDs | Controller instance queries | Numeric validations | Enum validations, including event | Entries passed to full-map Measure | Patch entries |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 1 | 2 | 2 | 1 | 1 |
| 16 | 1 | 32 | 17 | 16 | 1 |
| 64 | 1 | 128 | 65 | 64 | 1 |
| 256 | 1 | 512 | 257 | 256 | 1 |
| 1,024 | 1 | 2,048 | 1,025 | 1,024 | 1 |
| 4,096 | 1 | 8,192 | 4,097 | 4,096 | 1 |

The [scaling contract tests](../server/Networking/TagsReplication.Scaling.spec.luau) assert query/patch scope and exact complete baseline truth at 1, 64 and 512 active IDs. They intentionally avoid asserting today's full-map traversal count: a future generic optimization should retain the contract while reducing that cost. There are no wall-clock pass/fail thresholds.

## Exact guarantee and recommendation

For a batch of mutations, aggregate recomputation is limited to touched visible IDs and the instances queried for those IDs. Untouched timing anchors remain exact. Countdown-only and private-only mutations do not invoke N3. Live patches contain changed entries and explicit visible occurrences, not every active entry.

This is **not** an end-to-end O(touched IDs) mutation guarantee. [The adapter snapshot](../../src/server/Networking/utils/TagsReplication.luau) clones its entire cached visible root after invalidation. [N3 capture](../../src/server/Networking/utils/PublicationCapture.luau) traverses the full new map and previous keys, validates and owns canonical entries, and calls the [codec](../../src/shared/Networking/CodecCompiler.luau) to measure the complete canonical value. A one-entry patch does not remove those costs.

**A generic N3 optimization is warranted before N7–N8 performance sign-off.** At 256 active Tags this machine already spent about 0.35 ms per single-domain refresh; 4,096 is a stress case at about 5.6 ms. For perspective, 50 serial refreshes at the measured 256-ID median would sum to about 17.8 ms before transport or other gameplay work. That is an arithmetic illustration, not a measured concurrent-server workload.

First profile a representative multi-Actor, multi-domain workload using the same counters. N7 suppresses ordinary regeneration publication, while N8 bounds visible active Actions at 256; their shapes and mutation rates differ, so these Tag timings cannot be assigned directly to either. Functional adapter work can proceed, but sparse wire patches must not be accepted as evidence of cheap publication.

The generic optimization should consider reusable validated immutable subtrees, structural sharing and cached encoded sizes, preserving schema ownership, atomic rejection, event barriers, grouping and baseline/recovery behavior. Identity reuse must be restricted to data proven immutable; arbitrary producer tables and a shallow `table.freeze` are insufficient. Subtree reuse alone still leaves root copying/key scans. A strict O(touched entries) target would additionally require a generic validated changed-key/capture contract and a snapshot representation that avoids a full root copy. That design belongs in N3 for all domains; do not add a Tags-specific validation or transport bypass.
