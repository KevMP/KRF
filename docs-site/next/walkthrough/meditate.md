---
title: Meditate
sidebar_label: 2. Meditate
sidebar_position: 3
description: Turn the starter's Focus Action into Meditate so players can gather Qi by holding F.
---

# Meditate

We've already got the Qi bonus from holding F. Let's turn the starter's Focus Action into a Meditate Action so players will be able to gather Qi through meditation.

## Start and stop meditation

We'll use an Action to keep meditation running while the player holds F. KRF runs Actions on an Actor, which holds a character's gameplay state.

Rename `src/server/Actions/Focus.luau` to `Meditate.luau` and replace its contents:

```lua title="src/server/Actions/Meditate.luau"
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local KRF = require(ReplicatedStorage.Packages.KRF)

local function Meditate(): KRF.ActionDefinition
	return {
		id = "Meditate",
		visibility = "ClientVisible",
		autoGrant = true,
		blockedTags = { "Meditating" },
		activeTags = { "Meditating" },
		onStopRequested = function(context: KRF.ActionExecutionContext): ()
			context:End()
		end,
	}
end

return Meditate
```

Everyone should be able to meditate, so we'll keep `autoGrant` enabled. While the Action runs, `activeTags` will apply the Meditating Tag. Including that same Tag in `blockedTags` will prevent a second meditation from starting on the character.

The `onStopRequested` callback will end meditation by calling `context:End()` when the server receives Stop. KRF will remove the active Tag if the Action ends or gets interrupted.

## Keep the bonus while meditating

The `Meditating` name in the Action needs a matching Tag definition. Tags record statuses on an Actor and can modify its Properties, so we can put the Qi bonus here.

The Focused Tag already has the modifier we need. Rename `src/server/Tags/Focused.luau` to `Meditating.luau` and update the names:

```lua title="src/server/Tags/Meditating.luau"
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local KRF = require(ReplicatedStorage.Packages.KRF)

local Meditating: KRF.TagDefinition = {
	id = "Meditating",
	duplicateBehavior = "Ignore",
	visibility = "ClientVisible",
	properties = { QiRegen = { add = 10 } },
}

return Meditating
```

While Meditating is present, its bonus of 10 will bring `QiRegen` up to 11. When the Action removes the Tag, the rate will return to 1.

## Connect F to Meditate

The server now has Meditate, but the client still uses the Focus name. Rename these two files to `Meditate.luau`:

- `src/shared/ActionRequests/Focus.luau`
- `src/client/ActionInputPolicies/Focus.luau`

Inside each file, change every `Focus` to `Meditate`. Keep the existing settings. The shared request entry should now look like this:

```lua title="src/shared/ActionRequests/Meditate.luau"
Meditate = {
	stop = {},
	allowInputInterrupt = true,
	requiresClientRelease = true,
	onDisconnect = "Interrupt",
},
```

This will let clients send a Stop request without parameters. The interruption settings will also let meditation stop if the game window loses focus or the player's connection closes.

The request entry declares which requests are allowed. The input policy decides when the client will send them. For `requiresClientRelease`, we need the `WhileDown` policy already used by Focus:

```lua title="src/client/ActionInputPolicies/Meditate.luau"
Meditate = { activation = "WhileDown" },
```

Pressing F will send Start; releasing it will send Stop. That Stop will reach the server's `onStopRequested` callback, which will end meditation and remove the Qi bonus.

F is already bound to `AbilitySlot1`. To finish connecting it, equip Meditate in that slot in `src/client/Controls/Loadout.luau`:

```lua
local equipped: { [string]: string } = {
	AbilitySlot1 = "Meditate",
}
```

## Show when you're meditating

Meditate has `visibility = "ClientVisible"`, so all clients will receive its active state. We'll read that state through `view:GetActions()` and show `Meditating` beside Qi in the existing label.

Replace the `status` function in `src/client/Hud.luau` with:

```lua
local function status(view: KRF.ActorView): string
	local text: string = meter(view:GetResources(), "Qi")

	if view:GetActions():IsActionActive("Meditate") then
		text ..= " · Meditating"
	end

	return text
end
```

## Try it

Press Play and hold F while Qi is below 100. You should see `Meditating` beside the meter as Qi fills at 11 per second. Release F and watch the indicator disappear. Qi should continue increasing at 1 per second.

## Next

We'll give players a reason to save Qi: a [breakthrough](./break-through) to a higher realm.
