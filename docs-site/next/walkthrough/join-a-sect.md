---
title: Join a sect
sidebar_label: 5. Join a sect
sidebar_position: 6
description: Let players join a sect with a Command, grant the sect's technique, and build techniques from stacking, ticking and toggled Tags.
---

# Join a sect

Every cultivator so far cultivates the same way. In this chapter players join one of two sects by pressing 1 or 2. Joining is permanent and teaches the sect's technique, which goes on E:

- The Flame sect's Kindle costs 30 Qi and speeds up Qi regeneration for 20 seconds. Using it again stacks the effect, up to three times.
- The Frost sect's Stillness is a stance you toggle on and off. While it's on, your Qi maximum is half again as large, but it costs 3 Qi every second.

## The techniques

Each technique is an Action that applies a Tag. Generate the Tags first:

```bash
npm run createTag -- --name Kindled --duration 20 --duplicate-behavior Stack --max-stacks 3 --property QiRegen:add=3 --visibility ClientVisible
npm run createTag -- --name StillMind --tick-interval 1 --property MaxQi:multiply=1.5 --visibility ClientVisible
```

Kindled stacks: each use adds an independent instance with its own 20-second timer, and each instance adds 3 to `QiRegen`. Once three are active, another use refreshes the one closest to running out instead of adding a fourth.

StillMind has no duration; it lasts as long as something holds it. Its `tickInterval` runs `onTick` every second, which is where the stance takes its cost. Give `src/server/Tags/StillMind.luau` its drain:

```lua title="src/server/Tags/StillMind.luau"
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local KRF = require(ReplicatedStorage.Packages.KRF)

local StillMind: KRF.TagDefinition = {
	id = "StillMind",
	tickInterval = 1,
	duplicateBehavior = "Ignore",
	visibility = "ClientVisible",
	onTick = function(actor: KRF.Actor, _deltaTime: number): ()
		local resources = actor:GetController("ResourceController") :: KRF.ResourceController

		resources:Drain("Qi", 3)
	end,
	properties = { MaxQi = { multiply = 1.5 } },
}

return StillMind
```

KRF's declarative `costs` are paid once, when an Action starts. A cost that continues while something is active is game logic, and a ticking Tag is a good place for it.

Now the Actions. Neither uses `--auto-grant`; nobody can use them until a sect grants one.

```bash
npm run createAction -- --name Kindle --requestable --cost Qi=30 --applied-tag Kindled
npm run createAction -- --name Stillness --recipe toggle --requestable --active-tag StillMind
```

The generated Kindle needs no changes:

```lua title="src/server/Actions/Kindle.luau"
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local KRF = require(ReplicatedStorage.Packages.KRF)

local function Kindle(): KRF.ActionDefinition
	return {
		id = "Kindle",
		visibility = "ClientVisible",
		appliedTags = { "Kindled" },
		costs = { Qi = 30 },
		onStart = function(context: KRF.ActionExecutionContext): ()
			context:End()
		end,
	}
end

return Kindle
```

`appliedTags` applies Kindled when the Action is accepted, and the Tag then outlives the Action, which ends at once. Meditate used `activeTags` instead, which removes the Tag when the Action stops. That is the main difference between the two techniques. Stillness holds StillMind as an `activeTags` entry, so the stance lasts exactly as long as the Action runs.

Meditate and Breakthrough used the held recipe, which runs only while the key is down. Stillness uses the toggle recipe instead. Its request entry allows a Stop without requiring a key release:

```lua title="src/shared/ActionRequests/Stillness.luau"
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local KRF = require(ReplicatedStorage.Packages.KRF)

local Stillness: KRF.ActionRequestSchemas = {
	Stillness = {
		stop = {},
	},
}

return Stillness
```

and its input policy uses `Toggle`:

```lua title="src/client/ActionInputPolicies/Stillness.luau"
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local KRF = require(ReplicatedStorage.Packages.KRF)

local Stillness: KRF.ActionInputPolicies = {
	Stillness = { activation = "Toggle" },
}

return Stillness
```

With `Toggle`, the first press starts Stillness and the next press asks to stop it. The generated `onStopRequested` ends it, and the multiplier on `MaxQi` goes with the Tag. If Qi was above the normal maximum at that moment, it drops to the maximum.

## Grant a technique

Whether a player may use an Action is a grant on their Actor. Grants have named sources, so the grant from a sect can be added and removed without touching grants from anywhere else. Keep each player's sect in a server module, `src/server/Sects.luau`:

```lua title="src/server/Sects.luau"
--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local KRF = require(ReplicatedStorage.Packages.KRF)

local TECHNIQUES: { [string]: string } = {
	Flame = "Kindle",
	Frost = "Stillness",
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

Joining a sect isn't an Action; it doesn't run over time or hold a lock. It's a one-off request from the client, which is what Commands are for. A Command declares what the client sends and what the server answers, and the server decides who may send it and what happens.

```bash
npm run createCommand -- --name ChooseSect --request-field "Sect:Enum(Flame|Frost)" --result-field "Technique:Enum(Kindle|Stillness)" --authorize OwnerActor
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
		Technique = KRF.Schema.Enum({ "Kindle", "Stillness" }),
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

Bind E to a third slot in `src/client/Controls/Keybinds.luau`:

```lua
AbilitySlot3 = {
	context = "Gameplay",
	type = Enum.InputActionType.Bool,
	bindings = {
		Keyboard = { keyCode = Enum.KeyCode.E },
		Gamepad = { keyCode = Enum.KeyCode.ButtonB },
	},
},
```

and add the slot, empty, in `src/client/Controls/Loadout.luau`:

```lua
local SLOTS: { string } = { "AbilitySlot1", "AbilitySlot2", "AbilitySlot3" }
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
			Loadout.Equip("AbilitySlot3", outcome.result.Technique)
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

Finally, show the techniques' Tags in the HUD's `status` function. The TagsView reports each Tag's stack count:

```lua
local kindled: KRF.ActiveTagSnapshot? = view:GetTags():GetTag("Kindled")

if kindled ~= nil then
	text ..= ` · Kindled x{kindled.stackCount}`
end
```

```lua
if view:GetTags():HasTag("StillMind") then
	text ..= " · Still mind"
end
```

## Checkpoint

Press 1. The announcement says you learned Kindle, and pressing 2 now reports `AlreadyInSect`. With at least 30 Qi, press E: Qi drops by 30, the HUD shows `Kindled x1`, and Qi climbs 3 per second faster. Use it twice more for `Kindled x3`. Reset your character and E still works.

In a second session, press 2 instead. E toggles Stillness: the maximum grows by half, to 150 in the first realm, and Qi slowly drains. Press E again and the maximum returns to 100.

## Next

[Test the game](./test-the-game) adds automated checks.
