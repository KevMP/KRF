---
title: Coordinated client controls
sidebar_label: Guide
---

# Coordinated client controls

When a player takes control of another character, its input bindings and Action routes may need to change with it. `ClientControls.Apply` installs those changes together, so a new route can use an input introduced in the same call.

Keep using the individual `InputRuntime` or `ClientActionRuntime` methods for changes that don't depend on each other.

## Install a complete control change

This assumes a current `actorView` and a registered, granted, parameterless `Movement.Dash` Action with a shared request entry:

```lua
local ok, reason = KRF.ClientControls.Apply({
	inputs = {
		{
			kind = "Set",
			sourceId = "Character",
			definition = {
				contexts = { Gameplay = { priority = 0, sink = false } },
				inputs = {
					Dash = {
						context = "Gameplay",
						type = Enum.InputActionType.Bool,
						bindings = { Keyboard = { keyCode = Enum.KeyCode.Q } },
					},
				},
			},
		},
	},
	profiles = {
		{
			kind = "Set",
			actor = actorView,
			sourceId = "Movement",
			profile = {
				routes = {
					{
						when = { kind = "Input", inputId = "Dash", gesture = "Pressed" },
						target = { kind = "Fixed", actionId = "Movement.Dash" },
					},
				},
			},
		},
	},
	contexts = { { contextId = "Gameplay", enabled = true } },
	selection = { kind = "Set", actor = actorView },
})
assert(ok, reason)
```

KRF validates the configuration that will remain after the whole batch. Removing an input and every route that uses it in the same call is valid too. The arrays describe a final configuration, so changing their order doesn't create intermediate states.

Omit a section to preserve it. To clear Actor selection, supply `selection = { kind = "Set" }`. Source IDs identify ownership within each system; an input source and a profile source can share a name without being the same entry.

## Keep continuity when nothing meaningful changed

An equivalent update does not recreate native input objects or discard recognition history just because `Apply` was called. Selecting the same Actor preserves continuity too.

A real Actor switch retires the old input ownership and recognition history. A key still held must return to neutral before it can start a fresh press. Route-only changes can invalidate an Action activation without pretending the physical input was released. An unchanged Dynamic route still sends release to the concrete Action originally selected.

Restoring an old declaration does not reattach an activation whose input ownership was retired. Its server lifetime still follows the original Action's rules.

## Handle focus and gamepad changes

Ordinary client initialization also installs control lifecycle handling. Losing window focus retires active input ownership and recognition history. Disconnecting a gamepad retires inputs whose bindings could depend on it, while inputs known to use only independent devices keep their continuity.

Native input signals don't identify which physical gamepad produced an input event, so KRF treats gamepad-capable or ambiguous bindings conservatively. Regaining focus or reconnecting a gamepad restores availability, but a held button must return to neutral before a fresh press can start an Action.

These are cancellations, not genuine releases. Automatic Action handling follows the original activation's [invalidation policy](../actions/routes#decide-what-cancellation-means), without sampling a Stop payload as if the player released the button.

## Understand the publication boundary

KRF installs the coordinated configuration before its public notifications run. A notification handler can query the installed input, profile and selection state together. `Apply` is synchronous and does not queue a batch called during input dispatch or another protected transition; it returns `DispatchInProgress`.

Native Roblox properties are still separate writes. Code directly observing framework-owned native instances does not receive a Roblox-wide transaction guarantee.

Validation failure leaves the installed configuration alone. If native installation fails, KRF attempts to restore declarations while retiring physical ownership where needed for safety. If restoration itself fails, the runtime faults and fails closed. A failed native transition cannot rewind what a player physically did.

A successful call installs local controls and processes required cancellation follow-ups. Those requests can still be pending, rejected or uncertain on the server. Observe [request outcomes](../actions/client-api#request-observations) when the game needs that decision; the call does not wait for server results or deferred listeners.

See the [ClientControls API](./api) for operation shapes and failure reasons.
