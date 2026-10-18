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

Application timestamps are captured at entry to the ordinary domain change callback, after N5 installation, using `Workspace:GetServerTimeNow`. These are **approximate mutation-to-consumer-observation delays**, including framework scheduling, wire delivery, N5 application and callback scheduling. They are not pure network transit times or exact internal installation timestamps. Signed samples and negative counts are retained to expose synchronized-clock error.

Each client acknowledges completed waves through a separate fixture-control Remote. The server also measures wave-start-to-client-acknowledgement using only `os.clock` on the server. That metric includes the whole Actor wave, client notification, fixture acknowledgement and return delivery; it is not a one-way latency estimate. Control traffic consumes local transport capacity but is excluded from framework payload-byte totals.

Framework traffic is counted at the real client Reliable endpoint. Completion drains one more Heartbeat so the last receive observer cannot be skipped by callback ordering. The server independently observes successful ordinary `ServerNetworking.SendReliable` calls, delegates unchanged to the real sender, and asserts exact equality of bytes and packet counts for each client. Only serialized KRF Actor buffer payloads are counted: baseline/model setup, handshake, fixture control, Roblox protocol overhead, compression and NIC traffic are not included.

Server batch timings cover TagController mutation, derived work, adapter update and synchronous N3/N4 journal/enqueue work. Network scheduling/encoding happens later and is reflected in Heartbeat intervals and client delays. Server/client Heartbeat distributions cover each armed workload through its drain; client windows include the short arm acknowledgement. Deep retained-state audits are deferred until all expected changes/events arrive. Test observers and correctness checks still add overhead.

Timing values are observations, with no machine-specific latency or frame thresholds. Correctness, complete delivery, counter equality and bounded completion are required. A 35-second phase deadline and 180-second fixture deadline detect hangs; the launcher has a separate 300-second process limit.
