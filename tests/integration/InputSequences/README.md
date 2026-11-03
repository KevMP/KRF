# Native sequence and custom recognizer checks

Run `npm run test:integration:i3` from the repository root with Studio and the
repository prerequisites installed. The existing native runner builds
`i3-input-sequences-test.project.json`, starts two clients through
`StudioTestService`, and retains results under ignored `build/i3-native/`.

The fixture uses normal `Client.Init()` installation, managed native IAS objects
and private Scriptable bindings. It checks released hand signs, immediate and
deferred prefixes, keyboard/gamepad binding overlays, wrong-sign resolution,
dormant and held context invalidation, analog custom recognition, same-root
I1/I2/custom/sequence alternatives, and source teardown.

A final 256-pattern catalog emits 4,096 results per client. The result includes
synchronous native Scriptable dispatch seconds for 16 X/X/Q iterations. This
includes engine and framework work and excludes the later wait for public
delivery. It is a reproducible observation, not a callback CPU or latency
guarantee. Scriptable bindings do not prove physical keyboard/gamepad dispatch,
native Priority/Sink arbitration or focus behavior; check those with hardware
in Studio.

The shared `tests/benchmarks/InputRecognition/Workload.luau` also records 8,192
scalar-state callbacks with deadline replacement, then 128 isolated malformed
results. The latter timing includes diagnostic warnings. Both sources are
removed and checked for stale ownership before terminal cleanup.

`tests/examples/InputSequences.luau` supplies declarations for X/Q/Z,
overlapping XQ/XQZ, explicit DeferredPrefix and a scalar-state sword swipe.
Custom callbacks are trusted Luau. Framework state and deadline budgets do not
sandbox callback CPU or external allocations.

For a hardware check, build this project with Rojo and replace the automatic
client script with a game client that initializes KRF, installs
`Examples.Inputs()` and one recognition declaration, enables `Signs`, and prints
the two public match events. Test X/Q/Z with genuine releases, remap Q to E and
ButtonY, and disable Signs both while held and after all releases. Confirm that
context invalidation never finishes an old partial pattern.
