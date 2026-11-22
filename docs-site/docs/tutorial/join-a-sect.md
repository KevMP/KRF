---
title: Join a sect
sidebar_label: 5. Join a sect
sidebar_position: 6
description: Let players choose a sect and unlock a technique with a server-authorized Command.
---

# Join a sect

Let's give players a choice of technique. They'll be able to join the Flame sect by pressing 1 or the Frost sect by pressing 2, then use their sect's Action with E.

- The Flame sect will grant the Kindle Action. Each use will cost 30 Qi and add 3 Qi per second to regeneration for 20 seconds. Players will be able to stack that bonus up to three times.
- The Frost sect will grant the Stillness Action. Players will be able to toggle it on and off. While active, it will increase their Qi limit by 50% and drain 3 Qi every second.

We'll remember the choice across respawns for the current session. Players will be able to choose again after leaving and rejoining.

## Give Kindle a stacking bonus

We'll put Kindle's regeneration bonus on a Kindled [Tag](/reference/tags/guide). Generate the Tag and the Action together:

```bash
npm run createTag -- --name Kindled --duration 20 --duplicate-behavior Stack --max-stacks 3 --property QiRegen:add=3 --visibility ClientVisible
npm run createAction -- --name Kindle --requestable --cost Qi=30 --applied-tag Kindled
```

Each application of Kindled will have its own 20-second timer and add 3 to `QiRegen`. With three stacks active, another application will refresh the stack closest to expiring.

The generated Kindle Action will include:

```lua
appliedTags = { "Kindled" },
costs = { Qi = 30 },
onStart = function(context: KRF.ActionExecutionContext): ()
	context:End()
end,
```

Kindle will apply the Tag and end immediately. Because it uses `appliedTags`, Kindled will keep running until its duration expires. Meditate used `activeTags`, which removes the Tag when the Action stops.

## Make Stillness a toggle

Stillness will keep its bonus active until the player turns it off. We'll use an active Tag named StillMind and the toggle Action recipe:

```bash
npm run createTag -- --name StillMind --tick-interval 1 --property MaxQi:multiply=1.5 --visibility ClientVisible
npm run createAction -- --name Stillness --recipe toggle --requestable --active-tag StillMind
```

The multiplier will increase `MaxQi` by 50%. We also need to drain Qi while the Tag is active. Replace `src/server/Tags/StillMind.luau` with:

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

`tickInterval = 1` schedules a 3-Qi drain once per second. The `_deltaTime` argument is the controller's step time, normally 0.1 seconds, so it doesn't measure the time since this Tag last ticked.

An Action's `costs` are paid once when it starts, so we're using the Tag callback for this ongoing drain. `Drain` will stop at 0; reaching 0 won't end Stillness.

The toggle recipe will generate a shared Stop entry and a client input policy. You can see the difference from Meditate in these entries:

```lua title="src/shared/ActionRequests/Stillness.luau"
Stillness = {
	stop = {},
},
```

```lua title="src/client/ActionInputPolicies/Stillness.luau"
Stillness = { activation = "Toggle" },
```

The first press of E will send Start; the next will send Stop. The generated `onStopRequested` callback will end Stillness and remove the StillMind Tag. If the current Qi value is above the restored maximum, KRF will clamp it to that maximum.

## Grant the chosen technique

We left `autoGrant` disabled for both techniques, so creating the Actions hasn't given players access to them yet. We'll grant one when a player joins a sect.

Create `src/server/Sects.luau` to store each player's choice and grant the matching Action:

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

`SetGrants("Sect", ...)` will keep this grant under a named source, separate from grants supplied by other gameplay systems. `Join` will reject a second choice during the same session.

## Restore the technique after a respawn

Respawning will create a new Actor, so we'll need to grant the technique again. The `chosen` table will still hold the player's sect until they leave the server.

In `src/server/PlayerActors.luau`, add this require at the top:

```lua
local Sects = require(script.Parent.Sects)
```

Then call `Restore` after a character registers. Replace the existing `register` function with:

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

## Accept the choice on the server

The client will send a sect name to the server. We'll handle that with a ChooseSect Command, which will return either the learned technique or a reason the choice was rejected.

```bash
npm run createCommand -- --name ChooseSect --request-field "Sect:Enum(Flame|Frost)" --result-field "Technique:Enum(Kindle|Stillness)" --authorize OwnerActor
```

Replace the generated module in `src/server/Commands/ChooseSect.luau` with:

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

The Enum schema will restrict the choice to Flame or Frost before the handler runs. `OwnerActor` will require the targeted Actor to belong to the player sending the request.

The handler will call our `Sects.Join` function. On success, KRF will send the technique name back to the client so it can equip the Action.

## Bind E to the technique

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

Add the slot to `SLOTS` in `src/client/Controls/Loadout.luau`. Leave it out of `equipped` for now; the client will fill it after the server accepts a sect choice:

```lua
local SLOTS: { string } = { "AbilitySlot1", "AbilitySlot2", "AbilitySlot3" }
```

## Send the sect choice

We'll use 1 and 2 to choose a sect and print the result in the client's Output window. Create `src/client/Sects.luau`:

```lua title="src/client/Sects.luau"
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local KRF = require(ReplicatedStorage.Packages.KRF)
local Loadout = require(script.Parent.Controls.Loadout)
local LocalCharacter = require(script.Parent.LocalCharacter)

local SECT_KEYS: { [Enum.KeyCode]: string } = {
	[Enum.KeyCode.One] = "Flame",
	[Enum.KeyCode.Two] = "Frost",
}

local Sects = {}

local function onResult(outcome: KRF.CommandResult): ()
	if outcome.commandId ~= "ChooseSect" then
		return
	end

	if outcome.status == "Accepted" then
		Loadout.Equip("AbilitySlot3", outcome.result.Technique)
		print(`You learned {outcome.result.Technique}. Press E to use it.`)
	elseif outcome.status == "Rejected" then
		warn(`You could not join: {outcome.reason}`)
	else
		warn("Your sect choice has no confirmed result yet. It may have been applied on the server.")
	end
end

function Sects.Start(): ()
	KRF.CommandRuntime.OnCommandResult:Connect(onResult)
	KRF.CommandRuntime.OnCommandUncertain:Connect(onResult)

	UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
		local sect: string? = SECT_KEYS[input.KeyCode]
		local view: KRF.ActorView? = LocalCharacter.Get()

		if processed or sect == nil or view == nil then
			return
		end

		local requestId: number?, reason: string? = KRF.CommandRuntime.Send("ChooseSect", view, { Sect = sect })

		if requestId == nil then
			warn(`Could not send sect choice: {reason}`)
		end
	end)
end

return Sects
```

Getting a request ID from `Send` won't mean the server has accepted the choice. We'll wait for `OnCommandResult` before equipping the technique. If the result becomes uncertain, `OnCommandUncertain` will report that separately; the server may already have applied the choice.

Add the require at the top of `src/client/Startup.client.luau`:

```lua
local Sects = require(script.Parent.Sects)
```

Then start it after the existing startup calls:

```lua
Sects.Start()
```

## Read the technique's Tags

Let's use the existing label to see how the bonuses behave. In `src/client/Hud.luau`, add this before `return text` in `status`:

```lua
local kindled: KRF.ActiveTagSnapshot? = view:GetTags():GetTag("Kindled")

if kindled ~= nil then
	text ..= ` · Kindled x{kindled.stackCount}`
end

if view:GetTags():HasTag("StillMind") then
	text ..= " · Still mind"
end
```

`GetTag` will give us Kindled's stack count. For StillMind, we only need `HasTag` to check whether the stance is active.

## Try it

Fill Qi, then press 1. Check client Output for the Kindle confirmation. Pressing 2 after that should report `AlreadyInSect`. Use E three times while you have enough Qi and watch the label reach `Kindled x3`. Each stack should add 3 to the regeneration rate and expire after 20 seconds.

Reset your character and gather at least 30 Qi before trying E again. Kindle should still work because the server restored its grant on the new Actor.

Start a fresh play session to try Frost. Gather some Qi, press 2, then press E. Stillness should raise the first realm's limit to 150. With Meditate off, you should see Qi drain over time. Press E again to end Stillness and return the limit to 100.

## Next

In [Test the game](./test-the-game), we'll check that advancing one character updates its Qi limit without changing another character.
