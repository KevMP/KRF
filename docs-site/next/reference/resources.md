---
title: Resources
sidebar_position: 1
description: Give Actors meters such as stamina, mana, ammo, cooldowns and charges, and read them on clients.
---

# Resources

When a character needs a meter that gets spent and refilled, make it a Resource. Stamina, mana, ammunition, an ability cooldown and ability charges are all Resources. Each Actor that has one keeps its own current value between a minimum and a maximum, and the value can regenerate on its own.

You define a Resource once, in your game's Resource catalog. The server owns every Actor's value: an Action pays for itself by declaring `costs`, other server code changes values through the Actor's `ResourceController`, and clients only read values through a `ResourcesView`. The examples on this page assume a project created with `create-krf`. For exact signatures and every failure reason, see the [Resources API](./resources-api).

## When a value should be a Resource

Values that aren't spent and refilled belong to other systems:

| You need | Use |
| --- | --- |
| A value that is spent, restored and refilled: stamina, mana, ammo, charges | A Resource |
| A readiness timer that recharges after use, like an ability cooldown | A Resource that is spent in full and regenerates |
| A number other systems modify, like max stamina or a regeneration rate | A [Property](/api/Property/property-controller) |
| A temporary or permanent status, like Stunned or Blocking | A [Tag](/api/Tags/tag-controller) |
| Other gameplay state clients must see, like a quest stage | A [replication domain](/Networking/replication-domains) |

A Resource's current value is never a Property. A Property can set a Resource's maximum or its regeneration rate, while the current value stays with the Resource.

## Define a Resource

Each definition is a module in your game's Resource catalog. A `create-krf` project loads every module under `src/server/Resources` and passes them to `Server.Init` as `resources`. Once the `MaxStamina` and `StaminaRegen` Properties exist, the generator writes the module for you:

```bash
npm run createResource -- --name Stamina --max MaxStamina --regen StaminaRegen --visibility ClientVisible
```

```lua title="src/server/Resources/Stamina.luau"
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local KRF = require(ReplicatedStorage.Packages.KRF)

local Stamina: KRF.ResourceDefinition = {
	id = "Stamina",
	max = { propertyName = "MaxStamina" },
	visibility = "ClientVisible",
	autoAssign = true,
	regen = { rate = { propertyName = "StaminaRegen" } },
}

return Stamina
```

| Field | Default | Meaning |
| --- | --- | --- |
| `id` | required | Unique, non-empty name used by every API, such as `"Stamina"` |
| `max` | required | Upper bound, as a [numeric source](#numeric-sources) |
| `min` | `{ value = 0 }` | Lower bound, as a numeric source |
| `initialValue` | the resolved maximum | Value on assignment. It must sit within the bounds that the Properties' default values give |
| `visibility` | required | `"ClientVisible"` to send it to every client, or `"ServerOnly"` to send it to none |
| `autoAssign` | `false` | Assign to every Actor when it registers |
| `regen` | none | `{ rate = source }`, in units per second. The default rate can't be negative |

`Server.Init` checks every definition before it accepts any of them. If one is invalid, it returns a failure with `system = "Resource"` and a reason from the [definition failures](./resources-api#definition-failures) list. KRF ignores fields it doesn't recognize, so a misspelled field such as `autoAsign` fails silently.

### Numeric sources

`min`, `max` and `regen.rate` each take one numeric source. Use a fixed number, such as `{ value = 100 }`, when every Actor shares it. Use a Property, such as `{ propertyName = "MaxStamina" }`, when the number differs per Actor or changes during play. The Property must be registered in your Property catalog, and its `defaultBaseValue` supplies the starting number; a numeric source can't carry a default of its own.

## Bounds and regeneration from Properties

A Property source follows the Actor's resolved Property value, so modifiers from active Tags change the Resource too. A `Winded` Tag that halves `StaminaRegen` halves the regeneration of every Actor that has the Tag, and the Resource needs no code for it.

When KRF assigns a Resource that reads a Property the Actor doesn't have yet, it gives the Actor that Property at its registered default. An existing Actor value is kept. When a Property later changes, KRF resolves the new bounds and rate before any listener runs, then fires one Resource change for the result.

Bounds clamp the current value but never fill it. Lowering the maximum pulls the current value down with it, while raising the maximum leaves the current value where it was, so call `Restore` or `SetCurrent` if your design wants a refill. If a Property change would put the maximum below the minimum, or make any value non-finite, the Resource keeps its last valid bounds and rate.

To give one Actor different numbers, set its Properties when you register it:

```lua
local actor: KRF.Actor?, reason: string? = KRF.ActorRuntime.RegisterActor(bossModel, {
	properties = { MaxStamina = 500 },
})
```

## Assign Resources to Actors

An Actor has only the Resources assigned to it. Set `autoAssign = true` for meters every character has, and KRF assigns them at registration. For a Resource only some Actors earn, such as mana after an unlock, call `ResourceController:AddResource(id, initialValue?)` at that moment. The optional value replaces the definition's `initialValue` and is clamped to the Actor's bounds.

A newly assigned Resource starts at the value passed to `AddResource` if there is one, otherwise at the definition's `initialValue`, otherwise at the Actor's resolved maximum. It stays assigned for the Actor's lifetime, because KRF has no way to unassign a Resource. To take one away in practice, keep it at its minimum or block the Actions that use it with a Tag.

## Change values on the server

Get the Actor's controller first:

```lua
local resources: KRF.ResourceController? = actor:GetController("ResourceController") :: KRF.ResourceController?
```

Then pick the method that matches what the game is doing:

| Intent | Method | At a bound |
| --- | --- | --- |
| Pay an exact amount, or nothing | `Spend(id, amount)` | Fails with `InsufficientResourceValue` and changes nothing |
| Check whether a payment would succeed | `CanSpend(id, amount)` | Changes nothing |
| Add an amount | `Restore(id, amount)` | Stops at the maximum |
| Remove up to an amount | `Drain(id, amount)` | Stops at the minimum and still succeeds |
| Set an exact value | `SetCurrent(id, value)` | Clamps into the bounds |

Spending counts only what sits above the minimum. With a minimum of 10 and a current value of 30, an Actor can spend at most 20. Each of these methods returns `true` on success, or `false` and a reason, and a call that leaves the value unchanged succeeds without firing an event.

### Pay for Actions with `costs`, not `Spend`

When an Action uses a Resource, declare the price on the Action. KRF checks every cost and pays them all at once when it accepts the Action:

```lua
costs = { Stamina = 20 },
resourceRequirements = { Stamina = { minPercent = 0.5 } },
```

KRF pays `costs` once, on acceptance, and never refunds them on its own. `resourceRequirements` checks a condition and spends nothing. If you call `Spend` before requesting an Action, or inside its `onCanStart`, the player can be charged for an Action that KRF then rejects. [Action Resources](/Action/action-resources) covers percentage costs, multipliers and rejection reasons.

Use `ResourceController` methods for changes that aren't an Action's price, such as a pickup that restores mana, a trap that drains stamina, or a refund your design grants.

## Regeneration

A Resource with `regen` gains its rate per second while the Actor is enabled, in steps of 0.1 seconds, and stops at its maximum. KRF reads the rate fresh on each step, so a Tag that changes the rate takes effect on the next one. A rate of zero or less does nothing; Resources never decay on their own. To drain a meter over time, call `Drain` from your own loop.

## React to changes on the server

`OnResourceChanged` fires after a Resource's current value or bounds change, and its payload carries the old and new values:

```lua
resources.OnResourceChanged:Connect(function(change: KRF.ResourceChange)
	if change.resourceId == "Stamina" and change.currentNewValue <= change.minNewValue then
		print(`{change.actor:GetId()} is exhausted`)
	end
end)
```

The event fires on every regeneration step that changes the value, so a regenerating Resource can fire it up to ten times a second. Keep listeners cheap. A change to the regeneration rate alone fires nothing. When one operation changes several Resources, such as an Action paying two costs, KRF finishes all the changes first and then fires once per Resource, in Resource ID order.

`OnResourceAdded` fires once when a Resource is assigned, with the Actor and the Resource ID.

## Read Resources on clients

KRF sends every `ClientVisible` Resource of every Actor to every connected client, so other players receive your character's values too. A `ServerOnly` Resource, including its ID, reaches no client at all, not even the owner's. Resources have no owner-only setting; to show a value only to its owner, publish it through a [replication domain](/Networking/replication-domains) with `audience = "Owner"`.

Clients read values through the Actor's view:

```lua
local resources: KRF.ResourcesView = actorView:GetResources()
local stamina: KRF.ResourceSnapshot? = resources:GetResource("Stamina")
```

The server doesn't send a message for each regeneration step. The client works out the current value from the last value it received, the time since then and the rate, and `GetCurrent` returns that estimate. Read it every frame for a smooth bar. The client's `OnResourceChanged` fires only when the server sends a new value: after a spend, restore, drain or assignment, or when the bounds or rate change. It stays silent while the value regenerates, which makes it right for one-off reactions such as flashing a bar when it drops sharply, and wrong as the only trigger for redrawing a bar.

This bar assumes `actorView` is the local character's ActorView and `fill` is the bar's inner Frame:

```lua title="A stamina bar"
local RunService = game:GetService("RunService")

RunService.RenderStepped:Connect(function()
	local stamina: KRF.ResourceSnapshot? = actorView:GetResources():GetResource("Stamina")

	if stamina ~= nil and stamina.max > stamina.min then
		fill.Size = UDim2.fromScale((stamina.current - stamina.min) / (stamina.max - stamina.min), 1)
	end
end)
```

## Cooldowns and charges

A cooldown is a Resource that an Action requires to be full, spends in full, and then regenerates:

```lua title="src/server/Resources/AbilityCooldown.luau"
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local KRF = require(ReplicatedStorage.Packages.KRF)

local AbilityCooldown: KRF.ResourceDefinition = {
	id = "AbilityCooldown",
	max = { value = 1 },
	visibility = "ClientVisible",
	autoAssign = true,
	regen = { rate = { value = 1 / 3 } },
}

return AbilityCooldown
```

The ability declares `resourceRequirements = { AbilityCooldown = { minPercent = 1 } }` and `costs = { AbilityCooldown = 1 }`. The player can use it again three seconds later, and the client can draw the cooldown from the Resource's estimate.

Charges use the same shape with a larger maximum. With `max = { value = 3 }`, a cost of 1 and a rate of `1 / 5`, the Action holds up to three uses and earns one back every five seconds.
