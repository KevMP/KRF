---
title: Break through
sidebar_label: 3. Break through
sidebar_position: 4
description: Hold R with a full bar of Qi for five seconds to reach a higher realm with a larger Qi maximum.
---

# Break through

We've got a way to gather Qi. Now let's give players something to spend it on: a breakthrough to a higher realm of cultivation.

Players will be able to attempt a breakthrough by holding R with full Qi. Starting the attempt will spend all of their Qi. If they hold R for five seconds, they'll reach the next realm and double their Qi limit. Releasing R early will cancel the attempt without a refund.

## Define the realms

We'll give players four realms to progress through. Both the server and client will need the realm names, so create `src/shared/Realms.luau`:

```lua title="src/shared/Realms.luau"
--!strict
local Realms = {}

Realms.NAMES = { "Qi Condensation", "Foundation Establishment", "Core Formation", "Nascent Soul" }

function Realms.MaxQi(realm: number): number
	return 100 * 2 ^ (realm - 1)
end

return Realms
```

`MaxQi` will start at 100 and double with each realm: 200, 400, then 800.

## Remember each character's realm

Each character will need its own realm number. We'll keep it in a Cultivation Controller, an object KRF will create for each Actor and destroy when that Actor is unregistered.

Generate the Controller:

```bash
npm run createController -- --name Cultivation --depends-on PropertyController
```

The generator will create `src/server/Controllers/Cultivation.luau` and connect its catalog to `Server.Init`. Replace the generated module with:

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

The `realm` variable lives inside `factory`, so every Actor will get its own value. We need the PropertyController to update `MaxQi`, so `dependsOn` will make KRF create that Controller first.

When we call `Advance`, it will raise the realm and update `MaxQi`. The Qi Resource will pick up the new limit automatically. Raising the limit won't refill Qi, so players will have to gather more after a breakthrough.

The exported `Cultivation` type will let the Breakthrough Action call these methods. KRF also requires a `Destroy` method; ours has nothing to clean up yet.

## Add the Breakthrough Action

We'll use the held Action recipe again, just like Meditate. This time, we'll require full Qi and spend it when the Action starts:

```bash
npm run createAction -- --name Breakthrough --recipe held --requestable --auto-grant --requirement Qi:minPercent=1 --cost Qi:percent=1 --lock Stance --hook onCanStart --hook onUpdate
```

The generator will create the Action, its shared request entry and a `WhileDown` input policy. We'll keep the generated request and policy modules. Replace `src/server/Actions/Breakthrough.luau` with:

```lua title="src/server/Actions/Breakthrough.luau"
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local KRF = require(ReplicatedStorage.Packages.KRF)
local Cultivation = require(script.Parent.Parent.Controllers.Cultivation)

local DURATION: number = 5

local function Breakthrough(): KRF.ActionDefinition
	local elapsed: number = 0

	local function cultivationOf(actor: KRF.Actor): Cultivation.Cultivation
		return actor:GetController("Cultivation") :: Cultivation.Cultivation
	end

	return {
		id = "Breakthrough",
		visibility = "ClientVisible",
		autoGrant = true,
		resourceRequirements = { Qi = { minPercent = 1 } },
		costs = { Qi = { percent = 1 } },
		locks = { "Stance" },
		onCanStart = function(context: KRF.ActionStartContext): (boolean, string?)
			if cultivationOf(context.actor).IsAtPeak() then
				return false, "PeakRealm"
			end

			return true, nil
		end,
		onStopRequested = function(context: KRF.ActionExecutionContext): ()
			context:Interrupt("Released")
		end,
		onUpdate = function(context: KRF.ActionExecutionContext, deltaTime: number): ()
			elapsed += deltaTime

			if elapsed >= DURATION then
				cultivationOf(context.actor).Advance()
				context:End()
			end
		end,
	}
end

return Breakthrough
```

The requirement will reject attempts made before Qi is full. The cost will spend the full amount when KRF accepts the Action. Our `onCanStart` callback will also reject a breakthrough at the last realm, so a player at the peak won't lose Qi on another attempt.

Notice where `elapsed` is declared. KRF will call the Action's factory function for each activation, giving every attempt its own timer. While the Action runs, `onUpdate` will add the time since its last call. Once that reaches five seconds, we'll advance the realm and end the Action.

Releasing R early will send Stop to `onStopRequested`, where we'll interrupt the attempt. KRF won't refund the cost. After a successful breakthrough, the Action will already have ended when the player releases R.

## Prevent meditation during a breakthrough

We don't want players to keep the meditation bonus during a breakthrough. Both Actions will use a lock named `Stance`, which will prevent them from running together. We've already added it to Breakthrough; add these fields to the Meditate Action in `src/server/Actions/Meditate.luau`:

```lua
locks = { "Stance" },
interruptibleBy = { "Breakthrough" },
```

`interruptibleBy` will let Breakthrough interrupt Meditate to acquire the lock. With full Qi, players will be able to go straight from holding F to holding R. Meditate won't be allowed to interrupt Breakthrough, so pressing F during an attempt won't start meditation.

## Bind R

In `src/client/Controls/Keybinds.luau`, add a second ability slot beside `AbilitySlot1`:

```lua
AbilitySlot2 = {
	context = "Gameplay",
	type = Enum.InputActionType.Bool,
	bindings = {
		Keyboard = { keyCode = Enum.KeyCode.R },
		Gamepad = { keyCode = Enum.KeyCode.ButtonY },
	},
},
```

Then update `SLOTS` and `equipped` in `src/client/Controls/Loadout.luau`:

```lua
local SLOTS: { string } = { "AbilitySlot1", "AbilitySlot2" }
```

```lua
local equipped: { [string]: string } = {
	AbilitySlot1 = "Meditate",
	AbilitySlot2 = "Breakthrough",
}
```

Let's show when an attempt is running. In the `status` function in `src/client/Hud.luau`, replace the existing Meditate check with:

```lua
if view:GetActions():IsActionActive("Breakthrough") then
	text ..= " · Breaking through"
elseif view:GetActions():IsActionActive("Meditate") then
	text ..= " · Meditating"
end
```

## Try it

Hold F until Qi reads `100/100`, then hold R. Qi should drop to 0 and the label should show `Breaking through`. Keep holding R for five seconds and watch the maximum change to 200. You'll still have the few points of Qi that regenerated during the attempt.

Try R before Qi is full; it shouldn't start an attempt. Then refill Qi, hold R and release it after a second or two. The attempt should stop without raising the maximum or refunding the spent Qi.

## Next

Our Cultivation Controller now tracks the realm on the server. In [Show realms to everyone](./show-realms), we'll replicate it to clients.
