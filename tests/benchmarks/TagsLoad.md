# Native multi-Actor Tags load test

Run `npm run test:integration:tags-load` from the repository root. The runner builds `tags-load-test.project.json` and launches a real Studio server with two native clients. Run Studio jobs serially. Logs and a complete `result.json` are written under `build/tags-load/<run-id>/`.

This exercises ordinary `Server.Init`, `Actors.RegisterActor`, automatic TagController installation, N3 publication, N4 recipient scheduling and serialization, actual Reliable RemoteEvents, normal `Client.Init` consumer installation, N5 DomainViews and typed TagsViews. There is no injected consumer, simulated transport, direct client state installation or production-code change.

## Workload

The server tests **25, 50 and 100 simultaneously registered Actors**, retiring the entire population before creating the next. Both clients observe every Actor. Models are minimal anchored Parts, without animation, character physics or combat AI.

Each Actor starts with nine active visible Tag IDs and twelve visible instances:

| Tags | Shape |
| --- | --- |
| Alive, Combat, Grounded | Three persistent statuses |
| Haste, Fortified, Regeneration | Three finite buffs; Regeneration has a real server tick callback |
| Burning | Three finite stacks, already at cap |
| Poison | Two finite stacks |
| Combo | One indefinite stack |

Two private server Tags, AIAlert and Cooldown, add two more instances; Cooldown also ticks. The full visible catalog has ten IDs because Stunned is initially absent. It appears on odd mutation generations and is removed on even generations.

For each population, the test runs:

1. Complete ordinary initial baselines and Model binding on both clients.
2. A 650 ms quiet interval with real countdown/ticks plus private-only refreshes: zero new N3 commits and zero framework Actor packets are required.
3. **Steady:** twelve waves scheduled 200 ms apart. Every wave mutates every Actor once, giving a nominal five committed batches per Actor per second while running.
4. **Burst:** three more waves for every Actor, synchronously with no yield between them. At 100 Actors this creates 300 committed batches before the next network scheduling frame.
5. Ordinary authoritative Actor removal and client teardown; final client reset.

Each batch adds one Combo stack, refreshes Haste, refreshes Burning at cap, adds/removes Stunned and refreshes private AIAlert. All four visible lifecycle occurrences publish together through the existing Tag mutation batch. This is a combat-like synthetic workload, not a claim about every game's typical mutation rate. Combo reaches sixteen stacks after fifteen batches. Each Actor therefore has nine or ten active visible IDs, and peaks at 28 visible instances plus two private instances. The largest population reaches **1,000 visible Actor/Tag entries and 3,000 authoritative Tag instances**, using ten shared visible catalog IDs rather than thousands of different definitions.

## Assertions and measurement boundaries

The test requires exactly one N3 commit per Actor batch, every applied generation on both clients, four semantic occurrences per batch attributed to the correct Actor, exact aggregate counts, immutable state, stable untouched timing anchors, correct typed final truth, no private metadata/state/events, no unexpected recovery baseline, and empty retired views. It identifies generations from immutable `DomainChange.current`; it does not assume asynchronous callback completion order or infer lifecycle events from state differences.

Application timestamps are captured at entry to the ordinary domain change callback, after N5 installation, using `Workspace:GetServerTimeNow`. These are **approximate mutation-to-consumer-observation delays**, including framework scheduling, wire delivery, N5 application and callback scheduling. They are not pure network transit times or exact internal installation timestamps. Signed samples and negative counts are retained to expose synchronized-clock error; neither recorded run had negative samples.

Each client acknowledges completed waves through a separate fixture-control Remote. The server also measures wave-start-to-client-acknowledgement using only `os.clock` on the server. That metric includes the whole Actor wave, client notification, fixture acknowledgement and return delivery; it is not a one-way latency estimate. Control traffic consumes local transport capacity but is excluded from framework payload-byte totals.

Framework traffic is counted at the real client Reliable endpoint. Completion drains one more Heartbeat so the last receive observer cannot be skipped by callback ordering. The server independently observes successful ordinary `ServerNetworking.SendReliable` calls, delegates unchanged to the real sender, and asserts exact equality of bytes and packet counts for each client. Only serialized KRF Actor buffer payloads are counted: baseline/model setup, handshake, fixture control, Roblox protocol overhead, compression and NIC traffic are not included.

Server batch timings cover TagController mutation, derived work, adapter update and synchronous N3/N4 journal/enqueue work. Network scheduling/encoding happens later and is reflected in Heartbeat intervals and client delays. Server/client Heartbeat distributions cover each armed workload through its drain; client windows include the short arm acknowledgement. Deep retained-state audits are deferred until all expected changes/events arrive. Test observers and correctness checks still add overhead.

Timing values are observations, with no machine-specific latency or frame thresholds. Correctness, complete delivery, counter equality and bounded completion are required. A 35-second phase deadline and 180-second fixture deadline detect hangs; the launcher has a separate 300-second process limit.

## Recorded results

Two fresh Studio processes on 2026-10-18, Intel i9-9900K @ 3.60 GHz, Studio file version `0, 743, 0, 7431133`. The server and both clients share this desktop. Read the [first](./results/tags-load-2026-10-18-run1.json) and [second](./results/tags-load-2026-10-18-run2.json) result sets for all counts, means, minima, maxima, frame sample counts and acknowledgement measurements.

Both runs passed all six cases. Each run delivered **2,625 committed Actor batches**, **5,250 client state notifications** and **21,000 client semantic occurrences** across the two clients. Initial baselines, private-only work and removals are outside those load counts. Client received bytes/packets equalled server successful sends in every case.

The following table uses the second run. Payload is per client over that entire case, not bytes per second.

| Actors | Mode | Batches | Server batch median (µs) | Client-observed median / p95 (ms) | Server Heartbeat p95 (ms) | Payload per client (bytes) |
| ---: | --- | ---: | ---: | ---: | ---: | ---: |
| 25 | Steady | 300 | 78.0 | 28.2 / 34.7 | 18.1 | 32,358 |
| 25 | Burst | 75 | 88.6 | 39.6 / 61.9 | 16.9 | 8,252 |
| 50 | Steady | 600 | 77.3 | 31.8 / 36.4 | 18.1 | 64,716 |
| 50 | Burst | 150 | 110.4 | 51.1 / 86.5 | 22.2 | 16,495 |
| 100 | Steady | 1,200 | 78.9 | 37.5 / 62.0 | 18.0 | 129,432 |
| 100 | Burst | 300 | 90.8 | 89.2 / 144.1 | 36.0 | 32,990 |

At 100 Actors, paced client-observed p95 was 57.9–62.0 ms across the runs. Burst p95 was 138.4–144.1 ms, with server Heartbeat p95 of 36.0–37.8 ms. Burst frame windows are short and contain few samples; their p95 is close to the worst observed frame, not a stable long-running tail estimate.

The result supports a narrower conclusion than a server capacity claim: this population delivered correct state and events over the real framework transport, while synchronized bursts produced appreciable frame stalls and longer client delay. The earlier [single-Actor CPU measurement](./TagsPublication.md) remains useful for isolating full-map capture cost, but cannot replace this transport test. A production capacity decision still needs longer runs on target server hardware, more/remote recipients, real gameplay/physics and network latency/loss conditions. Generic N3 optimization remains worth profiling; the observed burst delay also includes N4 budgets/flushes and client scheduling, so these numbers cannot all be attributed to N3.
