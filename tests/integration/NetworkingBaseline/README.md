# Native Networking memory soak

Run `npm run test:integration:networking-soak` on Windows with Roblox Studio,
Rokit tools and repository dependencies installed. The command starts one Studio
server and two real clients for approximately 45 minutes. Keep the session alive;
the launcher allows 50 minutes including startup and shutdown.

Use `npm run test:integration:networking-soak -- -Smoke` for an approximately
80-second setup check. `-StudioPath <path>` selects a Studio executable.

The full session uses 75 Actors, normal consumer installation, real transports
and the built-in Tags domain. Phases are 5 minutes warmup, 18 minutes at up to
25 refreshes/second, 18 minutes at up to 100 refreshes/second, and 4 minutes with
all Actors retired. Three Actors are replaced each load minute. Missed mutation
ticks are skipped rather than replayed as a burst. Production budgets remain
unchanged.

Minute samples and five-minute/phase-boundary quiet checkpoints contain scalar
heaps, diagnostics, live counts and cumulative lifecycle/event counts. Quiet
checkpoints pause mutations, drain, and assert both clients match canonical Tag
state and the complete semantic-event count. A fixed histogram summarizes pump
times; its p95 is a bin upper bound, not an exact percentile. No forced GC,
per-frame histories or retired Actor/View lists are retained. The server keeps
only the small, duration-bounded checkpoint report; allow for that report's own
memory cost when interpreting heap floors.

Results, source hashes, logs and existing asynchronous OS process telemetry are
written under ignored `build/networking-baseline/<run>/`. Correlate host samples
with checkpoint `unixMs`; OS process CPU includes Roblox engine work. KRF encoded
bytes are not wire bandwidth. Commands and Hints are not exercised; their exposed
ownership gauges are checked but their traffic lifecycles are outside this test.

Exit success proves workload, delivery, bounded ownership and final cleanup
assertions. It does **not** automatically prove absence of a memory leak. Review
equivalent quiet checkpoints by process: PASS needs no convincing progressive
growth; unresolved growth is SUSPICIOUS or INCONCLUSIVE, and failed correctness
is FAIL. Normal GC peaks and process caching alone do not prove a leak.
