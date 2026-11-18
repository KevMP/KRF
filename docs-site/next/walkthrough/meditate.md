---
title: Meditate
sidebar_label: 2. Meditate
sidebar_position: 3
description: Turn the starter's Focus into meditation and learn how a key press becomes a server-side Action.
---

# Meditate

Holding F already speeds up Qi; it just isn't called meditation yet. In this chapter you rename Focus to Meditate and Focused to Meditating. Every technique later in the game is built from the same pieces, so the chapter also explains what each one does.

## The Action

An Action is something an Actor does: it starts, runs, and ends or is interrupted. The server decides whether it may start and owns its whole lifetime. Rename `src/server/Actions/Focus.luau` to `Meditate.luau`:

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

An Action module returns a factory function rather than a table. KRF calls it for every activation, so local variables inside it belong to one activation; the breakthrough in chapter 6 relies on that.

`autoGrant` lets every Actor use the Action without being granted it first. `activeTags` gives the Actor the Meditating Tag for as long as the Action runs and removes it when the Action stops, however it stops. `blockedTags` refuses to start a second meditation while one is running.

When the player lets go of F, the client asks the server to stop. `onStopRequested` decides what that means, and here it ends the meditation. The client's release is only a request; the server could ignore it.

## The Tag

Rename `src/server/Tags/Focused.luau` to `Meditating.luau`:

```lua title="src/server/Tags/Meditating.luau"
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local KRF = require(ReplicatedStorage.Packages.KRF)

local Meditating: KRF.TagDefinition = {
	id = "Meditating",
	duplicateBehavior = "Ignore",
	visibility = "ClientVisible",
	properties = {
		QiRegen = { add = 10 },
		WalkSpeed = { set = 0 },
	},
}

return Meditating
```

A Tag is a status an Actor has, optionally with modifiers on its Properties. Meditating keeps the starter's Qi bonus and adds a second modifier that sets `WalkSpeed` to 0. `WalkSpeed` is one of two Properties KRF registers for you, along with `JumpPower`.

## The client side

Clients can only request Actions that a shared module lists. Rename `src/shared/ActionRequests/Focus.luau` to `Meditate.luau` and rename its entry:

```lua title="src/shared/ActionRequests/Meditate.luau"
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local KRF = require(ReplicatedStorage.Packages.KRF)

local Meditate: KRF.ActionRequestSchemas = {
	Meditate = {
		stop = {},
		allowInputInterrupt = true,
		requiresClientRelease = true,
		onDisconnect = "Interrupt",
	},
}

return Meditate
```

This entry says what a client may send for Meditate. `stop = {}` lets it ask to stop, and `requiresClientRelease` means that stop must come from the player actually releasing the key. `onDisconnect = "Interrupt"` ends the meditation if the player leaves, and `allowInputInterrupt` lets the client cancel it when input is lost, for example when the window loses focus.

How a key press turns into requests is a client decision. Rename `src/client/ActionInputPolicies/Focus.luau` to `Meditate.luau`:

```lua title="src/client/ActionInputPolicies/Meditate.luau"
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local KRF = require(ReplicatedStorage.Packages.KRF)

local Meditate: KRF.ActionInputPolicies = {
	Meditate = { activation = "WhileDown" },
}

return Meditate
```

`WhileDown` starts the Action when the key goes down and asks to stop it when the key comes up. Without a policy, an Action fires once per press.

Finally, the loadout decides which Action each ability slot runs. In `src/client/Controls/Loadout.luau`, put Meditate in the first slot:

```lua
local equipped: { [string]: string } = {
	AbilitySlot1 = "Meditate",
}
```

## Show when you're meditating

Meditate is `ClientVisible`, so every client can see which Actors are running it. Add that to the HUD's `status` function in `src/client/Hud.luau`:

```lua
local function status(view: KRF.ActorView): string
	local text: string = meter(view:GetResources(), "Qi")

	if view:GetActions():IsActionActive("Meditate") then
		text ..= " · Meditating"
	end

	return text
end
```

## Checkpoint

Press Play and hold F. The HUD shows `Meditating` and Qi climbs 11 per second.

You can still walk while meditating, even though Meditating sets `WalkSpeed` to 0. KRF works out the new value but never moves characters itself; applying it to the Humanoid is the game's job, and that's the next chapter.

## Next

[Stand still while meditating](./stand-still) applies `WalkSpeed` to characters.
