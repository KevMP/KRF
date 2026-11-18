---
title: Break through
sidebar_label: 3. Break through
sidebar_position: 4
description: Hold R with a full bar of Qi for five seconds to reach a higher realm with a larger Qi maximum.
---

# Break through

Cultivators advance through realms. In this chapter a cultivator with a full bar of Qi can hold R to break through. The attempt spends all of their Qi; if they keep holding R for five seconds, they reach the next realm, whose Qi maximum is twice as large. Letting go early ends the attempt, and the Qi is lost.

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

Each cultivator's realm is game state KRF doesn't know about. Per-Actor game state belongs in a Controller, an object KRF creates for every Actor when it registers and destroys when it unregisters. KRF's own Resources, Tags and Actions are Controllers too, and yours sit alongside them:

```bash
npm run createController -- --name Cultivation --depends-on PropertyController
```

The generator writes `src/server/Controllers/Cultivation.luau` and adds a `controllers` catalog to `Server.Init`. Replace the module's contents:

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

`factory` runs once per Actor. `dependsOn` makes KRF create the Property Controller first, so the factory can look it up. The returned table needs a `Destroy` function; everything else on it is yours, and the exported `Cultivation` type lets other server code call it once it has the Controller from `actor:GetController("Cultivation")`.

`Advance` raises the realm and sets the Actor's base `MaxQi`, and the Qi Resource picks up the new maximum on its own. Raising a Resource's maximum never refills it, so a cultivator who just broke through starts the larger bar nearly empty.

## The Breakthrough Action

```bash
npm run createAction -- --name Breakthrough --recipe held --requestable --auto-grant --requirement Qi:minPercent=1 --cost Qi:percent=1 --lock Stance --hook onCanStart --hook onUpdate
```

The held recipe generates what Meditate already has: a request entry that needs a real key release, a `WhileDown` input policy, and an `onStopRequested` that ends the Action. Fill in `src/server/Actions/Breakthrough.luau`:

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

The requirement and cost together mean "only with a full bar, and spend all of it". KRF checks and pays them in one step when it accepts the request, so a cultivator who isn't full spends nothing.

`onCanStart` runs after those checks and can refuse with a reason; here it stops cultivators at the last realm. `onUpdate` runs up to 20 times a second while the Action is active and receives the time since the last call. `elapsed` is safe as a factory local because each activation gets its own.

Releasing R asks to stop, as it does for meditation, but this time `onStopRequested` interrupts the Action instead of ending it. KRF never refunds a cost, so letting go early loses the Qi; that's the price of a failed breakthrough. A successful attempt ends itself in `onUpdate`, so the release that follows has nothing left to stop.

## One stance at a time

Meditating while breaking through makes no sense. Both Actions should hold the same lock, named `Stance`, and a breakthrough should be allowed to replace a meditation already in progress. In `src/server/Actions/Meditate.luau`, add:

```lua
locks = { "Stance" },
interruptibleBy = { "Breakthrough" },
```

A lock is just a name; two Actions that hold it can't run at once. `interruptibleBy` lists the Actions allowed to take the lock from this one. Breakthrough lists nothing, so pressing F during a breakthrough does nothing, while holding R during a meditation ends the meditation and starts the breakthrough.

## Bind R

Add a second ability slot in `src/client/Controls/Keybinds.luau`, next to `AbilitySlot1`:

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

and fill it in `src/client/Controls/Loadout.luau`:

```lua
local SLOTS: { string } = { "AbilitySlot1", "AbilitySlot2" }
```

```lua
local equipped: { [string]: string } = {
	AbilitySlot1 = "Meditate",
	AbilitySlot2 = "Breakthrough",
}
```

Show the attempt in the HUD's `status` function:

```lua
if view:GetActions():IsActionActive("Breakthrough") then
	text ..= " · Breaking through"
elseif view:GetActions():IsActionActive("Meditate") then
	text ..= " · Meditating"
end
```

## Checkpoint

Hold F until Qi reads `100/100`, then hold R. Qi drops to 0 and the HUD shows `Breaking through`. Keep holding R for five seconds: the bar's maximum becomes 200, and it keeps filling from the few points it regenerated during the attempt. Holding R before the bar is full does nothing.

Fill the bar again, hold R and let go after a second or two. The attempt ends, the Qi is gone, and the maximum stays at 200.

## Next

[Show realms to everyone](./show-realms) lets every player see each other's realm.
