---
title: Dash
sidebar_label: 9. Dash
sidebar_position: 10
description: Add a dash triggered by double-tapping Shift, built from a Tag, a cooldown Resource and a short Action.
---

# Dash

Fights need a way to get out of the way. In this chapter a double tap of Shift gives a cultivator a short burst of speed, with a four-second cooldown. Almost all of it reuses what the game already has; the new part is recognizing a double tap.

## The dash itself

```bash
npm run createResource -- --name DashCooldown --max 1 --regen 0.25 --visibility ClientVisible
npm run createTag -- --name Dashing --property WalkSpeed:multiply=3 --visibility ClientVisible
npm run createAction -- --name Dash --recipe channel --duration 0.3 --requestable --auto-grant --blocked-tag KnockedOut --blocked-tag Meditating --blocked-tag BreakingThrough --active-tag Dashing --requirement DashCooldown:minPercent=1 --cost DashCooldown=1
```

The generated Action needs no changes:

```lua title="src/server/Actions/Dash.luau"
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local KRF = require(ReplicatedStorage.Packages.KRF)

local DURATION: number = 0.3

local function Dash(): KRF.ActionDefinition
	local elapsed: number = 0

	return {
		id = "Dash",
		visibility = "ClientVisible",
		autoGrant = true,
		blockedTags = { "KnockedOut", "Meditating", "BreakingThrough" },
		activeTags = { "Dashing" },
		resourceRequirements = { DashCooldown = { minPercent = 1 } },
		costs = { DashCooldown = 1 },
		onUpdate = function(context: KRF.ActionExecutionContext, deltaTime: number): ()
			elapsed += deltaTime

			if elapsed >= DURATION then
				context:End()
			end
		end,
	}
end

return Dash
```

For 0.3 seconds the Actor holds the Dashing Tag, which triples `WalkSpeed`, and the Movement Controller applies it like any other speed change. The dash is blocked while meditating, breaking through or knocked out, because those Tags root the cultivator and a tripled zero is still zero.

## Recognize a double tap

So far every ability has started on a plain key press. KRF's input layer can also recognize gestures on an input, such as a tap, a hold, a long hold or a double tap. In `src/client/Controls/Keybinds.luau`, add a `Dash` input bound to Shift after the ability slots:

```lua
Dash = {
	context = "Gameplay",
	type = Enum.InputActionType.Bool,
	bindings = {
		Keyboard = { keyCode = Enum.KeyCode.LeftShift },
		Gamepad = { keyCode = Enum.KeyCode.ButtonL3 },
	},
},
```

and declare its double tap next to `inputs`, inside the same `definition`:

```lua
gestures = {
	Dash = {
		DoubleTapped = { maxTapDurationSeconds = 0.25, maxGapSeconds = 0.3 },
	},
},
```

A press counts as a tap if it's released within 0.25 seconds, and a second press within 0.3 seconds of that release makes it a double tap.

The ability slots route through the loadout because their Actions can change. The dash never changes, so route it directly. In `src/client/Controls/Loadout.luau`, start the profile with a fixed route:

```lua
local profile: KRF.ControlProfile = {
	routes = {
		{
			when = { kind = "Input", inputId = "Dash", gesture = "DoubleTapped" },
			target = { kind = "Fixed", actionId = "Dash" },
		},
	},
}
```

The route's `gesture` is what makes it fire on the double tap rather than on every press.

## Checkpoint

Press Play and double-tap Shift while walking. You surge forward briefly, and another double tap does nothing until four seconds have passed. A single tap does nothing.

## Next

[Draw techniques](./draw-techniques) makes bolts and sect techniques visible.
