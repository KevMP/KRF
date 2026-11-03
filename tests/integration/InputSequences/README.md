# Native sequence and custom recognizer checks

Run `npm run test:integration:i3` from the repository root with Studio and the
repository prerequisites installed. The existing native runner builds
`i3-input-sequences-test.project.json`, starts two clients through
`StudioTestService`, and retains results under ignored `build/i3-native/`.

This is an intentionally red acceptance fixture. The current scaffold returns
`InvalidDefinition` when a source contributes sequences, groups or
recognizers. A fixture failure at that assertion is expected until recognition
compilation and dispatch are implemented. No tests are skipped or replaced by
synthetic success results.

The fixture uses normal `Client.Init()` installation, managed native IAS objects
and private Scriptable bindings. It checks released hand signs, immediate and
deferred prefixes, keyboard/gamepad binding overlays, wrong-sign resolution,
dormant context invalidation, analog custom recognition and source teardown.
Scriptable bindings exercise engine transitions; they do not prove physical
keyboard/gamepad dispatch, native Priority/Sink arbitration or focus behavior.
Those still require hardware checks in Studio.

`tests/examples/InputSequences.luau` supplies declarations for X→Q→Z,
overlapping XQ/XQZ, explicit DeferredPrefix and a scalar-state sword swipe. Its
comments identify the current scaffold limitation. Custom callbacks are trusted
Luau; the framework's state and deadline budgets do not sandbox callback CPU or
external allocations.

For a hardware check after implementation, build this project with Rojo and
replace the automatic client script with a game client that initializes KRF,
installs `Examples.Inputs()` and one recognition declaration, enables `Signs`,
and prints the two public match events. Test X/Q/Z with genuine releases, remap
Q to E and ButtonY, and disable Signs both while held and after all releases.
Confirm that context invalidation never finishes an old partial pattern.
