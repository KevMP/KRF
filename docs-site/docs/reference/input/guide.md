---
title: Input
sidebar_label: Guide
---

# Input

Name a control for what the player does, such as `Guard`. Gameplay can then listen for Guard while the player chooses whether to use F, a gamepad trigger or an on-screen button. `InputRuntime` manages those bindings through Roblox's native Input Action system and publishes KRF input events.

Use [Action routes](../actions/routes) when Guard should request a server Action. For local behavior such as opening a panel, subscribe to `OnInput` directly. InputRuntime also recognizes taps, holds and combinations; none of those declarations execute gameplay on their own.

## Declare inputs in a source

A source groups declarations that one part of the game owns. Base controls and player preferences can use separate sources, so changing a preference doesn't require rewriting the base controls.

After [client initialization](../getting-started/initialization), install a Bool input:

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = require(ReplicatedStorage.Packages.KRF)
local Input = KRF.InputRuntime

local ok, reason = Input.SetSource("Character", {
	contexts = {
		Gameplay = { priority = 0, sink = false },
	},
	inputs = {
		Guard = {
			context = "Gameplay",
			type = Enum.InputActionType.Bool,
			bindings = {
				Keyboard = { keyCode = Enum.KeyCode.F },
				Gamepad = { keyCode = Enum.KeyCode.ButtonL2 },
			},
		},
	},
})
assert(ok, reason)
assert(Input.SetContextEnabled("Gameplay", true))
```

New contexts start disabled. Keeping the same context owner preserves its enablement across source updates; transferring ownership to another source does not.

`SetSource` replaces the whole source, so include the declarations you want to keep. Passing an empty source removes its contribution. KRF copies and freezes declarations during installation; editing the original table later changes nothing.

## Contexts decide when controls participate

An input belongs to one context. For example, a menu can have its own context whose priority and `sink` settings let it consume bindings also used by gameplay. KRF applies those settings to the native `InputContext`; installing the context and enabling it are separate operations.

Enabling a context while its key is already held doesn't create a fresh press. Focus loss, loss of an input device and relevant configuration changes can also cancel an existing press. KRF requires neutral input before rearming an affected control. A `Cancelled` event lets consumers clear held behavior without treating it as a deliberate release.

When opening a menu also changes Action routes or the selected Actor, use [ClientControls](../controls/guide) to publish those changes together.

## Rebind a slot without taking over the input

Only one source may declare an input or context ID. A preferences source can instead replace an existing binding slot:

```lua
assert(Input.SetSource("Preferences", {
	priority = 10,
	bindingOverrides = {
		Guard = {
			Keyboard = { keyCode = Enum.KeyCode.G },
		},
	},
}))
```

Overrides replace a slot's entire binding definition. They cannot create an input or a new slot. The highest override source priority wins; a tie at the winning priority rejects the configuration. Removing `Preferences` reveals the base binding again.

An update must leave every dependency valid. To remove an input and its Action route, remove both through `ClientControls.Apply`. Separate calls can fail because the first proposed configuration still contains a reference to the missing input.

Changes requested during input delivery can be queued until delivery finishes. A query made in that callback can therefore still return the old configuration. See the [API's mutation contract](./api#source-declarations) for queued changes and failures.

## Observe semantic input

```lua
local connection = Input.OnInput:Connect(function(event)
	if event.inputId == "Guard" and event.kind == "Cancelled" then
		-- Clear game-owned local feedback for this input.
	end
end)
```

Bool inputs produce `Pressed` and `Released`; directional and viewport inputs produce `StateChanged`. Cancellation has its own event. Events identify the input and context, with a local timestamp and increasing ordinal for correlation. They do not expose raw Roblox input objects.

Queries such as `GetInput` and `GetEffectiveBindings` describe the installed configuration. To track an analog value, read `StateChanged` and keep the latest value in your consumer. Disconnect subscriptions when that consumer ends.

Use [recognition](./recognition) to share tap, hold and combination rules across consumers. If you use a native `InputActionLabel`, `BindActionLabel` keeps it associated with the effective native Action as bindings change.

See the [InputRuntime API](./api) for declaration fields, query results and failures.
