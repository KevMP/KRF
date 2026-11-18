---
title: Join a sect
sidebar_label: 8. Join a sect
sidebar_position: 9
description: Let players join a sect with a Command, grant the sect's technique, and add stacking and ticking Tags.
---

# Join a sect

Every cultivator so far has the same abilities. In this chapter players join one of two sects by pressing 1 or 2. Joining is permanent and teaches the sect's technique, which goes on E. The Flame sect's Ember sets its target burning, dealing damage every second and stacking up to three times. The Frost sect's Frost Palm chills its target, slowing them.

## The techniques

```bash
npm run createTag -- --name Burning --duration 6 --tick-interval 1 --duplicate-behavior Stack --max-stacks 3 --visibility ClientVisible
npm run createTag -- --name Chilled --duration 3 --duplicate-behavior Refresh --property WalkSpeed:multiply=0.6 --visibility ClientVisible
npm run createAction -- --name Ember --requestable --blocked-tag KnockedOut --requirement BoltCooldown:minPercent=1 --cost Qi=25 --cost BoltCooldown=1 --lock Stance --start-field X:F32 --start-field Y:F32 --start-field Z:F32
npm run createAction -- --name FrostPalm --requestable --blocked-tag KnockedOut --requirement BoltCooldown:minPercent=1 --cost Qi=25 --cost BoltCooldown=1 --lock Stance --start-field X:F32 --start-field Y:F32 --start-field Z:F32
```

The techniques share the bolt's cooldown Resource, so firing a sect technique also puts the bolt on cooldown, and the other way around. Unlike the bolt, they don't use `--auto-grant`: nobody can use them until a sect grants one.

Burning stacks, and each stack ticks on its own, so three stacks burn three times as fast. Give `src/server/Tags/Burning.luau` its damage:

```lua title="src/server/Tags/Burning.luau"
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local KRF = require(ReplicatedStorage.Packages.KRF)

local Burning: KRF.TagDefinition = {
	id = "Burning",
	defaultDuration = 6,
	tickInterval = 1,
	duplicateBehavior = "Stack",
	maxStacks = 3,
	visibility = "ClientVisible",
	onTick = function(actor: KRF.Actor, _deltaTime: number): ()
		local resources = actor:GetController("ResourceController") :: KRF.ResourceController

		resources:Drain("Vitality", 3)
	end,
}

return Burning
```

Chilled refreshes instead of stacking, so a second hit only restarts the timer, and its `WalkSpeed` modifier needs no code.

Each technique works like the bolt at a shorter range. Fill in `src/server/Actions/Ember.luau`:

```lua title="src/server/Actions/Ember.luau"
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local KRF = require(ReplicatedStorage.Packages.KRF)
local Combat = require(script.Parent.Parent.Combat)

local RANGE: number = 20
local DAMAGE: number = 10

local function Ember(): KRF.ActionDefinition
	return {
		id = "Ember",
		visibility = "ClientVisible",
		blockedTags = { "KnockedOut" },
		resourceRequirements = { BoltCooldown = { minPercent = 1 } },
		costs = {
			Qi = 25,
			BoltCooldown = 1,
		},
		locks = { "Stance" },
		onStart = function(context: KRF.ActionExecutionContext): ()
			local target: KRF.Actor? = Combat.Cast(context.actor, context.parameters, RANGE)

			if target ~= nil then
				Combat.Hit(target, DAMAGE, "Burning")
			end

			context:End()
		end,
	}
end

return Ember
```

`src/server/Actions/FrostPalm.luau` is the same with `"Chilled"` in place of `"Burning"`. Their generated input policies need the same aim as the bolt:

```lua title="src/client/ActionInputPolicies/Ember.luau"
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local KRF = require(ReplicatedStorage.Packages.KRF)
local Aim = require(script.Parent.Parent.Aim)

local Ember: KRF.ActionInputPolicies = {
	Ember = {
		startParameters = function(context: KRF.ActionInputContext): {
			X: number,
			Y: number,
			Z: number,
		}
			return Aim.FromMouse(context.actor)
		end,
	},
}

return Ember
```

Make `src/client/ActionInputPolicies/FrostPalm.luau` match, with `FrostPalm` in place of `Ember`.

Like the bolt, both techniques should be able to cut a meditation short. In `src/server/Actions/Meditate.luau`:

```lua
interruptibleBy = { "QiBolt", "Breakthrough", "Ember", "FrostPalm" },
```

## Grant a technique

Whether a player may use an Action is a grant on their Actor. Grants have named sources, so a sect grant and, say, an item grant can be added and removed independently. Keep each player's sect in a server module, `src/server/Sects.luau`:

```lua title="src/server/Sects.luau"
--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local KRF = require(ReplicatedStorage.Packages.KRF)

local TECHNIQUES: { [string]: string } = {
	Flame = "Ember",
	Frost = "FrostPalm",
}

local Sects = {}

local chosen: { [Player]: string } = {}

local function grant(actor: KRF.Actor, sect: string): (boolean, string?)
	local actions = actor:GetController("ActionController") :: KRF.ActionController

	return actions:SetGrants("Sect", { TECHNIQUES[sect] })
end

function Sects.Join(player: Player, actor: KRF.Actor, sect: string): (string?, string?)
	if chosen[player] ~= nil then
		return nil, "AlreadyInSect"
	end

	local granted: boolean, reason: string? = grant(actor, sect)

	if not granted then
		return nil, reason
	end

	chosen[player] = sect

	return TECHNIQUES[sect], nil
end

function Sects.Restore(player: Player, actor: KRF.Actor): ()
	local sect: string? = chosen[player]

	if sect ~= nil then
		grant(actor, sect)
	end
end

Players.PlayerRemoving:Connect(function(player: Player)
	chosen[player] = nil
end)

return Sects
```

`Join` grants the technique under the source `"Sect"` and remembers the choice. A respawn creates a new Actor with no grants, so `Restore` grants the remembered technique again. Call it from `src/server/PlayerActors.luau` right after a character registers:

```lua
local function register(player: Player, character: Model): ()
	local actor: KRF.Actor?, reason: string? = KRF.ActorRuntime.RegisterActor(character)

	if actor == nil then
		warn(`Could not register {player.Name}'s character as an Actor: {reason}`)
		return
	end

	Sects.Restore(player, actor)
end
```

and require `Sects` at the top of that file:

```lua
local Sects = require(script.Parent.Sects)
```

## The ChooseSect Command

Joining a sect isn't an Action; it doesn't run over time or use a Stance lock. It's a one-off request from the client, which is what Commands are for. A Command declares what the client sends and what the server answers, and the server decides who may send it and what happens.

```bash
npm run createCommand -- --name ChooseSect --request-field "Sect:Enum(Flame|Frost)" --result-field "Technique:Enum(Ember|FrostPalm)" --authorize OwnerActor
```

Fill in the handler in `src/server/Commands/ChooseSect.luau`:

```lua title="src/server/Commands/ChooseSect.luau"
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local KRF = require(ReplicatedStorage.Packages.KRF)
local Sects = require(script.Parent.Parent.Sects)

local ChooseSect: KRF.CommandDefinition = {
	id = "ChooseSect",
	target = "Actor",
	request = KRF.Schema.Struct({
		Sect = KRF.Schema.Enum({ "Flame", "Frost" }),
	}),
	result = KRF.Schema.Struct({
		Technique = KRF.Schema.Enum({ "Ember", "FrostPalm" }),
	}),
	authorize = KRF.CommandAuthorization.OwnerActor,
	handle = function(context: KRF.CommandContext, request: { Sect: string }): KRF.CommandHandlerResult
		local actor: KRF.Actor = assert(context.actor, "ChooseSect targets an Actor")
		local technique: string?, reason: string? = Sects.Join(context.player, actor, request.Sect)

		if technique == nil then
			return { accepted = false, reason = reason }
		end

		return { accepted = true, result = { Technique = technique } }
	end,
}

return ChooseSect
```

`target = "Actor"` means the client names an Actor with each request, and `OwnerActor` lets only the player whose character that Actor is send it. `handle` returns either an accepted result, which the client receives as `Technique`, or a rejection with a short reason.

## Choose a sect

Bind E to a fourth slot in `src/client/Controls/Keybinds.luau`:

```lua
AbilitySlot4 = {
	context = "Gameplay",
	type = Enum.InputActionType.Bool,
	bindings = {
		Keyboard = { keyCode = Enum.KeyCode.E },
		Gamepad = { keyCode = Enum.KeyCode.ButtonR1 },
	},
},
```

and add the slot, empty, in `src/client/Controls/Loadout.luau`:

```lua
local SLOTS: { string } = { "AbilitySlot1", "AbilitySlot2", "AbilitySlot3", "AbilitySlot4" }
```

Then create `src/client/Sects.luau`, which sends the Command when the player presses 1 or 2 and equips the technique the server grants:

```lua title="src/client/Sects.luau"
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local KRF = require(ReplicatedStorage.Packages.KRF)
local Hud = require(script.Parent.Hud)
local Loadout = require(script.Parent.Controls.Loadout)
local LocalCharacter = require(script.Parent.LocalCharacter)

local SECT_KEYS: { [Enum.KeyCode]: string } = {
	[Enum.KeyCode.One] = "Flame",
	[Enum.KeyCode.Two] = "Frost",
}

local Sects = {}

function Sects.Start(): ()
	KRF.CommandRuntime.OnCommandResult:Connect(function(outcome: KRF.CommandResult)
		if outcome.commandId ~= "ChooseSect" then
			return
		end

		if outcome.status == "Accepted" then
			Loadout.Equip("AbilitySlot4", outcome.result.Technique)
			Hud.Announce(`You learned {outcome.result.Technique}. Press E to use it.`)
		else
			Hud.Announce(`You could not join: {outcome.reason}`)
		end
	end)

	UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
		local sect: string? = SECT_KEYS[input.KeyCode]
		local view: KRF.ActorView? = LocalCharacter.Get()

		if processed or sect == nil or view == nil then
			return
		end

		KRF.CommandRuntime.Send("ChooseSect", view, { Sect = sect })
	end)
end

return Sects
```

`Send` only means the request left; the answer arrives later through `OnCommandResult`. If the connection drops before the answer, KRF reports the request through `OnCommandUncertain` instead, because it can't know whether the server ran it. Pressing the key again is safe here, since the server rejects a second sect.

Start the module in `src/client/Startup.client.luau`:

```lua
local Sects = require(script.Parent.Sects)
```

```lua
Sects.Start()
```

## Checkpoint

Press 1. The announcement says you learned Ember, and E now fires it. Pressing 2 reports `AlreadyInSect`. In a two-player test, hit the other player with Ember three times, as fast as the cooldown allows. Burning lasts six seconds, so all three stacks are active at once, and their Vitality drops faster with each one. Reset your character and E still works.

## Next

[Dash](./dash) adds a way to move quickly.
