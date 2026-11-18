---
title: Break through
sidebar_label: 6. Break through
sidebar_position: 7
description: Channel a full bar of Qi for five seconds to reach a higher realm and a larger Qi maximum.
---

# Break through

Cultivators advance through realms. In this chapter a cultivator with a full bar of Qi can press R to break through: they spend all of it and stay rooted for five seconds, then reach the next realm, whose Qi maximum is twice as large. Getting hit during those five seconds ruins the attempt, and the Qi is lost.

## Realms

The realm numbers are plain game rules that both server and client will need, so keep them in a shared module, `src/shared/Realms.luau`:

```lua title="src/shared/Realms.luau"
--!strict
local Realms = {}

Realms.NAMES = { "Qi Condensation", "Foundation Establishment", "Core Formation", "Nascent Soul" }

function Realms.MaxQi(realm: number): number
	return 100 * 2 ^ (realm - 1)
end

return Realms
```

Each cultivator's realm is game state KRF doesn't know about, which makes it another Controller:

```bash
npm run createController -- --name Cultivation --depends-on PropertyController
```

```lua title="src/server/Controllers/Cultivation.luau"
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local KRF = require(ReplicatedStorage.Packages.KRF)
local Realms = require(ReplicatedStorage.Shared.Realms)

export type Cultivation = KRF.Controller & {
	GetRealm: () -> number,
	IsAtPeak: () -> boolean,
	Advance: () -> (),
}

local Cultivation: KRF.ControllerDefinition = {
	key = "Cultivation",
	factory = function(actor: KRF.Actor): KRF.Controller
		local properties = actor:GetController("PropertyController") :: KRF.PropertyController
		local realm: number = 1

		local cultivation: Cultivation = {
			GetRealm = function(): number
				return realm
			end,
			IsAtPeak = function(): boolean
				return realm >= #Realms.NAMES
			end,
			Advance = function(): ()
				realm += 1
				properties:SetBaseProperty("MaxQi", Realms.MaxQi(realm))
			end,
			Destroy = function(): () end,
		}

		return cultivation
	end,
	dependsOn = { "PropertyController" },
}

return Cultivation
```

The Controller returns more than `Destroy`. Its exported `Cultivation` type describes the functions other server code can call once it has the Controller from `actor:GetController("Cultivation")`.

`Advance` raises the realm and sets the Actor's base `MaxQi`, and the Qi Resource picks up the new maximum on its own. Raising a Resource's maximum never refills it, so a cultivator who just broke through starts the larger bar nearly empty.

## The Breakthrough Action

```bash
npm run createTag -- --name BreakingThrough --property WalkSpeed:set=0 --visibility ClientVisible
npm run createAction -- --name Breakthrough --recipe channel --duration 5 --requestable --auto-grant --blocked-tag KnockedOut --active-tag BreakingThrough --requirement Qi:minPercent=1 --cost Qi:percent=1 --lock Stance --hook onCanStart --hook onStart --hook onEnd --hook onInterrupt
```

The channel recipe generates an Action that ends itself after `--duration` seconds. Fill in the hooks in `src/server/Actions/Breakthrough.luau`:

```lua title="src/server/Actions/Breakthrough.luau"
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local KRF = require(ReplicatedStorage.Packages.KRF)
local Cultivation = require(script.Parent.Parent.Controllers.Cultivation)

local DURATION: number = 5

local function Breakthrough(): KRF.ActionDefinition
	local elapsed: number = 0
	local disruptions: { KRF.Connection } = {}

	local function cultivationOf(actor: KRF.Actor): Cultivation.Cultivation
		return actor:GetController("Cultivation") :: Cultivation.Cultivation
	end

	local function stopListening(): ()
		for _, connection: KRF.Connection in disruptions do
			connection:Disconnect()
		end
	end

	return {
		id = "Breakthrough",
		visibility = "ClientVisible",
		autoGrant = true,
		blockedTags = { "KnockedOut" },
		activeTags = { "BreakingThrough" },
		resourceRequirements = { Qi = { minPercent = 1 } },
		costs = { Qi = { percent = 1 } },
		locks = { "Stance" },
		onCanStart = function(context: KRF.ActionStartContext): (boolean, string?)
			if cultivationOf(context.actor).IsAtPeak() then
				return false, "PeakRealm"
			end

			return true, nil
		end,
		onStart = function(context: KRF.ActionExecutionContext): ()
			local tags = context.actor:GetController("TagController") :: KRF.TagController

			local function disrupt(_actor: KRF.Actor, tagId: string): ()
				if tagId == "Staggered" then
					context:Interrupt("Disrupted")
				end
			end

			disruptions = { tags.OnTagAdded:Connect(disrupt), tags.OnTagRefreshed:Connect(disrupt) }
		end,
		onUpdate = function(context: KRF.ActionExecutionContext, deltaTime: number): ()
			elapsed += deltaTime

			if elapsed >= DURATION then
				cultivationOf(context.actor).Advance()
				context:End()
			end
		end,
		onEnd = stopListening,
		onInterrupt = stopListening,
	}
end

return Breakthrough
```

The requirement and cost together mean "only with a full bar, and spend all of it". KRF never refunds a cost, so an interrupted breakthrough loses the Qi. That's the penalty for being hit.

`onCanStart` runs after those checks and can refuse with a reason; here it stops cultivators at the last realm. `onUpdate` runs up to 20 times a second while the Action is active and receives the time since the last call.

Being hit should end the attempt, but `blockedTags` only matters at the start. To react during the channel, `onStart` listens to the Actor's Tags and interrupts the Action itself when Staggered appears. It listens for a refresh too, because Staggered refreshes instead of stacking when a cultivator is hit twice. `onEnd` and `onInterrupt` disconnect those listeners whichever way the Action finishes. The listeners and `elapsed` are safe as factory locals because each activation gets its own.

Breakthrough holds the Stance lock without allowing interruption, so no technique can start while it runs. Meditation must still give way to it. In `src/server/Actions/Meditate.luau`:

```lua
interruptibleBy = { "QiBolt", "Breakthrough" },
```

## Bind R

Add a third ability slot in `src/client/Controls/Keybinds.luau`:

```lua
AbilitySlot3 = {
	context = "Gameplay",
	type = Enum.InputActionType.Bool,
	bindings = {
		Keyboard = { keyCode = Enum.KeyCode.R },
		Gamepad = { keyCode = Enum.KeyCode.ButtonB },
	},
},
```

and fill it in `src/client/Controls/Loadout.luau`:

```lua
local SLOTS: { string } = { "AbilitySlot1", "AbilitySlot2", "AbilitySlot3" }
```

```lua
local equipped: { [string]: string } = {
	AbilitySlot1 = "Meditate",
	AbilitySlot2 = "QiBolt",
	AbilitySlot3 = "Breakthrough",
}
```

Breakthrough has no input policy because it doesn't need one: it takes no parameters, so each press sends one start request.

Show the channel in the HUD's `status` function:

```lua
if view:GetTags():HasTag("KnockedOut") then
	text ..= " · Knocked out"
elseif view:GetTags():HasTag("BreakingThrough") then
	text ..= " · Breaking through"
elseif view:GetActions():IsActionActive("Meditate") then
	text ..= " · Meditating"
end
```

## Checkpoint

Hold F until Qi reads `100/100`, then press R. Your Qi drops to 0 and you can't move for five seconds. Afterwards the bar's maximum is 200, and it keeps filling from the few points it regenerated during the channel. Pressing R before the bar is full does nothing.

In a two-player test, start a breakthrough and have the other player bolt you before the five seconds are up. The attempt ends, the Qi is gone, and your maximum stays the same.

## Next

[Show realms to everyone](./show-realms) lets every player see each other's realm.
