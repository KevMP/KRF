---
sidebar_position: 14
---

# Coordinated client controls

Use `ClientControls.Apply` when one change must install or withdraw input definitions, Action profiles, context enablement, and Actor selection together. Simple equipment changes still use `ClientActionRuntime.SetProfileSource`; a keybind overlay still uses `InputRuntime.SetSource`.

This guide assumes [client initialization](../initializing-krf#client-initialization) succeeded and the ActorViews are available.

## Install and remove a manual

The example assumes an existing semantic input `X` and a registered, granted `Combat.Thunder` Action whose request schema accepts no parameters. `actorView` is the current registry-owned ActorView.

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local Controls = require(KRF.client.Controls.ClientControls)

local installed, reason = Controls.Apply({
	inputs = {
		{
			kind = "Set",
			sourceId = "Manual.Thunder",
			definition = {
				contexts = { HandSigns = { priority = 3000, sink = true } },
				inputs = {
					Sign = {
						context = "HandSigns",
						type = Enum.InputActionType.Bool,
						bindings = { Keyboard = { keyCode = Enum.KeyCode.Z } },
					},
				},
				sequences = {
					Thunder = { steps = { "X", "Sign" }, maxGapSeconds = 1, maxTotalSeconds = 2 },
				},
			},
		},
	},
	profiles = {
		{
			kind = "Set",
			actor = actorView,
			sourceId = "Manual.Thunder",
			profile = {
				routes = {
					{
						when = { kind = "Sequence", sequenceId = "Thunder" },
						target = { kind = "Fixed", actionId = "Combat.Thunder" },
					},
				},
			},
		},
	},
	contexts = { { contextId = "HandSigns", enabled = true } },
})
if not installed then
	warn(reason)
end
```

Remove the referencing profile and defining input source in the same call:

```lua
local removed, reason = Controls.Apply({
	inputs = { { kind = "Remove", sourceId = "Manual.Thunder" } },
	profiles = { { kind = "Remove", actor = actorView, sourceId = "Manual.Thunder" } },
})
if not removed then
	warn(reason)
end
```

Validation uses the final graph. New inputs and sequences may be referenced immediately, and removing both sides of a dependency succeeds regardless of array order. Removing the input source alone fails while any installed profile still references it, including shadowed, gated, or noncontrolled Actors' profiles.

Input source IDs and profile source IDs have independent ownership. Matching strings do not create an automatic teardown link. Each profile source is additionally scoped to its ActorView object identity.

## Switch to a mount or another form

When `Gameplay.Human` and `Gameplay.Beast` are already registered, switch their enablement and controlled Actor together:

```lua
local changed, reason = Controls.Apply({
	selection = { kind = "Set", actor = beastView },
	contexts = {
		{ contextId = "Gameplay.Human", enabled = false },
		{ contextId = "Gameplay.Beast", enabled = true },
	},
	profiles = {
		{
			kind = "Set",
			actor = beastView,
			sourceId = "Form.Beast",
			profile = {
				routes = {
					{
						when = { kind = "Input", inputId = "PrimaryAttack", gesture = "Pressed" },
						target = { kind = "Fixed", actionId = "Beast.Claw" },
					},
				},
			},
		},
	},
})
if not changed then
	warn(reason)
end
```

Omitting `selection` preserves the Actor. `selection = { kind = "Set" }` explicitly clears it. Selecting the same Actor with equivalent declarations preserves held inputs, recognition histories, native instances, effective routes, and active Action ownership.

A real Actor switch cancels previous input epochs and cross-Actor recognition history. Holding a key through the switch cannot start the new Actor's Action; the input must reach trustworthy neutral and activate again. The previous Action keeps its original Actor, policy, and Start receipt for Interrupt or Keep.

## Continuity and cancellation

A route/profile/gate-only change can invalidate an Action without cancelling the underlying physical input. Unrelated recognizers and direct semantic subscribers continue. Rebinding an effective slot invalidates affected input ownership while preserving independent bindings such as the unchanged gamepad slot.

Replacing a context under the same defining source preserves enablement unless explicitly overridden. Transferring the same context ID to another source starts a new disabled lifetime unless the batch enables it; old epochs are invalidated even when the ID matches.

An unchanged dynamic route is not re-resolved during Apply. If game-owned equipment changes Rasengan to Fireball behind that route, the existing Rasengan still receives its original genuine-release Stop. A fresh press can select Fireball. Removing the route or switching Actor instead applies the captured Action invalidation policy without sampling release aim. See [Action input](./action-input).

Genuine release and forced cancellation remain distinct. A provably genuine release from an unaffected epoch during native writes is delivered once after publication, with Action release handling before recognition. Synthetic context-disable ends and uncertain invalidated epochs cannot become gameplay Stop.

Focus loss and gamepad disconnection retire affected input epochs, dependent recognition, and automatic Action ownership. Ambiguous device provenance is treated conservatively; bindings that prove independence remain live. Background input cannot rearm an unavailable input. Focus recovery or reconnect requires trustworthy neutral and fresh activation. Safety events arriving during Apply are coalesced and processed before managed starts resume.

## Publication and failures

Apply is synchronous and returns after local publication and a bounded attempt to admit original follow-ups. It does not wait for server acknowledgement.

The ordering is:

1. Normalize and validate the complete desired graph.
2. Enter the input owner's native dispatch barrier and retire invalidated epochs before native writes.
3. Install recognition, profiles, Actor selection, and local Action retirement.
4. Publish the coherent graph to mandatory private observers.
5. Attempt original follow-ups in Start admission order and drain pending focus/device safety work.
6. Resume managed starts, preserve proven unaffected releases, and schedule public observations.

```text
Final-graph preflight
  -> input barrier -> epoch retirement -> IAS diff
  -> recognition + profiles + Actor + Action retirement
  -> coherent publication -> original follow-up admission + pending safety work
  -> managed starts + scheduled public observations
```

This guarantees a coherent KRF-visible transition. Roblox IAS Instance properties are still written separately; scripts watching those instances directly may observe individual native writes.

Successfully admitted original Interrupts enter ordered egress before subsequent managed Starts. If admission capacity refuses a follow-up, the existing bounded Action request pending mechanism handles it. Delivery before a later Start is then not guaranteed. Unknown is not permission to replay, and `true` never proves that the server accepted or terminated an Action.

Deterministic rejection leaves installed configuration, selection, and live ownership intact. Native failure is different: the input owner either proves coherent declaration restoration with safe rearm of retired epochs, or faults and cleans up. It never claims to restore uncertain physical history. Public observation errors cannot undo a committed graph.

Reentrant public mutations during preparation, private publication, or follow-up cleanup return `DispatchInProgress` immediately. Ordinary standalone InputRuntime source-callback deferral remains unchanged. Public observations run after coherent cleanup and may request a new explicit mutation.

See [ClientControls API](/api/Client/client-controls) for the strict ChangeSet fields and failure results.
