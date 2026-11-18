---
title: Resources
description: Per-Actor meters such as stamina, mana, ammo, cooldowns and charges.
---

# Resources

A Resource is a meter an Actor owns: a current value that stays between a minimum and a maximum, and can regenerate over time. Stamina, mana, ammunition, a dash cooldown and ability charges are all Resources.

The server owns every Resource. Game code changes values through the Actor's `ResourceController`, Actions pay for themselves with declarative `costs`, and clients read values through a read-only `ResourcesView`.

## Choose the right system

| You need | Use |
| --- | --- |
| A value that is spent, restored and refilled: stamina, mana, ammo, charges | A Resource |
| A readiness timer that recharges after use, like a dash cooldown | A Resource that is spent in full and regenerates |
| A number other systems modify, like walk speed, max stamina or a regeneration rate | A [Property](/api/Property/property-controller) |
| A temporary or permanent status, like Stunned or Blocking | A [Tag](/api/Tags/tag-controller) |
| Other gameplay state clients must see, like a quest stage | A [replication domain](/Networking/replication-domains) |

A Resource's current value is never a Property. Properties can supply its bounds and regeneration rate, but the current value belongs to the Resource.

## How a Resource works

1. **Define** it once in your game's Resource catalog. A definition describes the meter; it holds no per-Actor value.
2. **Assign** it to an Actor. The Actor gets its own current value, resolved bounds and regeneration rate.
3. **Change** the value on the server: an Action pays its `costs`, or game code calls `ResourceController` methods.
4. **Regenerate** automatically while the Actor is enabled, if the definition has a rate.
5. **Read** it on clients through `ResourcesView`, if the definition is `ClientVisible`.

## Define a Resource

Each definition is a module in your game's Resource catalog. A project created with `create-krf` loads every module under `src/server/Resources` and passes them to `Server.Init` as `resources`. Once the `MaxStamina` and `StaminaRegen` Properties exist, create the module with the generator:

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
| `initialValue` | the resolved maximum | Value on assignment. Must sit within the default bounds |
| `visibility` | required | `"ClientVisible"` to replicate to clients, or `"ServerOnly"` |
| `autoAssign` | `false` | Assign to every Actor when it registers |
| `regen` | none | `{ rate = source }`, in units per second. The default rate must not be negative |

Startup validates every definition before KRF accepts any of them. A bad definition makes `Server.Init` return a failure with `system = "Resource"` and one of the [definition failure reasons](#definition-failures).

### Numeric sources

`min`, `max` and `regen.rate` each take one numeric source:

| Source | Example | Use it when |
| --- | --- | --- |
| Fixed | `{ value = 100 }` | Every Actor uses the same number |
| Property | `{ propertyName = "MaxStamina" }` | The number differs per Actor or changes during play |

A Property source must name a Property registered in your Property catalog. Its `defaultBaseValue` is the starting number; Resource definitions do not take their own default.

## Bounds and regeneration from Properties

A Property source follows the Actor's resolved Property value, including modifiers from active Tags. For example, a `Winded` Tag that multiplies `StaminaRegen` by 0.5 halves the regeneration of every Actor that has it, without any Resource code.

- **Assigning the Resource gives the Actor its Properties.** If the Actor lacks a Property the Resource needs, KRF assigns it at its registered default. An existing Actor value is kept.
- **Changes apply immediately.** When a Property changes, KRF resolves the new bounds and rate before any listener runs, and fires one Resource change for the result.
- **The current value is clamped, never refilled.** Lowering the maximum pulls the current value down to it. Raising the maximum leaves the current value where it was; restore it yourself if the design calls for a refill.
- **Invalid results are ignored.** If a Property change would make the maximum smaller than the minimum, or any value non-finite, the Resource keeps its last valid bounds and rate.

To give one Actor different numbers, set its Properties when you register it:

```lua
local actor: KRF.Actor?, reason: string? = KRF.ActorRuntime.RegisterActor(bossModel, {
	properties = { MaxStamina = 500 },
})
```

## Assign Resources to Actors

An Actor has only the Resources assigned to it. There are two ways to assign one:

- **`autoAssign = true`** assigns the Resource to every Actor at registration. Use it for meters every character has.
- **`ResourceController:AddResource(id, initialValue?)`** assigns it to one Actor later, for example when a player unlocks mana. The optional value replaces the definition's `initialValue` and is clamped to the Actor's bounds.

The starting value is, in order of priority: the value passed to `AddResource`, the definition's `initialValue`, then the Actor's resolved maximum.

A Resource stays assigned for the Actor's lifetime; there is no way to unassign one. To make it unusable, keep it at its minimum or gate the Actions that use it with a Tag.

## Change values on the server

Get the Actor's controller, then call the method that matches the intent:

```lua
local resources: KRF.ResourceController? = actor:GetController("ResourceController") :: KRF.ResourceController?
```

| Intent | Method | At a bound |
| --- | --- | --- |
| Pay an exact amount, or nothing | `Spend(id, amount)` | Fails with `InsufficientResourceValue` and changes nothing |
| Check whether a payment would succeed | `CanSpend(id, amount)` | Changes nothing |
| Add an amount | `Restore(id, amount)` | Stops at the maximum |
| Remove up to an amount | `Drain(id, amount)` | Stops at the minimum and still succeeds |
| Set an exact value | `SetCurrent(id, value)` | Clamps into the bounds |

Spending measures what sits above the minimum, not above zero: with a minimum of 10 and a current value of 30, at most 20 can be spent.

Every method returns `true` on success, or `false` and a reason. A change that leaves the value where it was succeeds without firing an event.

### Pay for Actions with `costs`, not `Spend`

When an Action uses a Resource, declare it on the Action. KRF checks every cost and pays them together when the Action is accepted:

```lua
costs = { Stamina = 20 },
resourceRequirements = { Stamina = { minPercent = 0.5 } },
```

`costs` are paid once, on acceptance, and are never refunded automatically. `resourceRequirements` only checks a condition and spends nothing. Calling `Spend` before requesting an Action, or inside its `onCanStart`, can charge for an Action that is then rejected. See [Action Resources](/Action/action-resources) for percentages, multipliers and the rejection reasons.

Call `ResourceController` methods for changes that are not an Action's price: a pickup that restores mana, a trap that drains stamina, a refund your design grants.

## Regeneration

A Resource with `regen` advances by its rate every 0.1 seconds while the Actor is enabled, and stops at its maximum. The rate is read fresh each step, so a Tag that changes the rate takes effect on the next step.

A rate of zero or less does nothing; Resources never decay on their own. To drain a meter over time, call `Drain` from your own loop.

## React to changes on the server

`OnResourceChanged` fires after a Resource's current value or bounds change, with the old and new values:

```lua
resources.OnResourceChanged:Connect(function(change: KRF.ResourceChange)
	if change.resourceId == "Stamina" and change.currentNewValue <= change.minNewValue then
		print(`{change.actor:GetId()} is exhausted`)
	end
end)
```

- It fires on every regeneration step that changes the value, up to ten times a second per Resource. Keep listeners cheap.
- A change to the regeneration rate alone fires no server event.
- When one operation changes several Resources, such as an Action paying two costs, each Resource fires once, in Resource ID order, after all of them have changed.

`OnResourceAdded` fires once when a Resource is assigned, with the Actor and the Resource ID.

## Read Resources on clients

A `ClientVisible` Resource replicates to every client that can see its Actor, not only to the Actor's own player. Keep a value `ServerOnly` if other players must not see it. `ServerOnly` Resources are never sent to clients, and their IDs are not either.

Read values through the Actor's view:

```lua
local resources: KRF.ResourcesView = actorView:GetResources()
local stamina: KRF.ResourceSnapshot? = resources:GetResource("Stamina")
```

Two things differ from the server:

- **`GetCurrent` is an estimate.** The server does not send regeneration steps. The client works out the current value from the last value it received, the time since then and the rate. Read it every frame for a smooth bar.
- **`OnResourceChanged` fires only when the server sends a new value**: a spend, restore, drain, assignment, or a change to the bounds or rate. It does not fire while the value regenerates. Use it for one-off reactions, such as flashing a bar when it takes a hit, and per-frame reads for display.

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

Clients cannot change Resources. A client asks the server to do something through an Action request or a Command, and the server decides.

## Cooldowns and charges

A cooldown is a Resource that an Action requires to be full, spends in full, and regenerates:

```lua title="src/server/Resources/DashCooldown.luau"
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local KRF = require(ReplicatedStorage.Packages.KRF)

local DashCooldown: KRF.ResourceDefinition = {
	id = "DashCooldown",
	max = { value = 1 },
	visibility = "ClientVisible",
	autoAssign = true,
	regen = { rate = { value = 1 / 3 } },
}

return DashCooldown
```

The dash then declares `resourceRequirements = { DashCooldown = { minPercent = 1 } }` and `costs = { DashCooldown = 1 }`. It can be used again three seconds later, and the client can draw the cooldown from the Resource's estimate.

Charges work the same way with a larger maximum. With `max = { value = 3 }`, a cost of 1 and a rate of `1 / 5`, the Action holds up to three uses and earns one back every five seconds.

## Common mistakes

| Mistake | Instead |
| --- | --- |
| Calling `Spend` before `RequestAction`, or in `onCanStart` | Declare `costs` on the Action |
| Storing a meter's current value in a Property | Make it a Resource; use Properties for its bounds and rate |
| Writing a custom controller or RemoteEvent to replicate a meter | Make it `ClientVisible` and read `ResourcesView` |
| Redrawing a HUD only from the client's `OnResourceChanged` | Read the view every frame; the event skips regeneration |
| Expecting a higher maximum to refill the meter | Call `Restore` or `SetCurrent` when the design calls for it |
| Assuming `ClientVisible` is private to the owner | Every client that sees the Actor receives it; use `ServerOnly` for secrets |

## API

### `ResourceDefinition` {#resource-definition}

The table each catalog module returns. See [Define a Resource](#define-a-resource) for its fields.

### `ResourceController` {#resource-controller}

The server-side owner of one Actor's Resources. Every Actor has one; get it with `actor:GetController("ResourceController")`.

| Kind | Members |
| --- | --- |
| Methods | [`AddResource`](#add-resource) · [`HasResource`](#has-resource) · [`GetCurrent`](#get-current) · [`GetMin`](#get-min) · [`GetMax`](#get-max) · [`CanSpend`](#can-spend) · [`Spend`](#spend) · [`Restore`](#restore) · [`Drain`](#drain) · [`SetCurrent`](#set-current) |
| Events | [`OnResourceAdded`](#on-resource-added) · [`OnResourceChanged`](#on-resource-changed) |
| Infrastructure | [`Step`](#step) · [`Destroy`](#destroy) |

#### `AddResource(resourceId: string, initialValueOverride: number?) -> (boolean, string?)` {#add-resource}

Assigns a registered Resource to the Actor. The override, when given, must be a finite number and is clamped to the Actor's bounds.

| Failure | Cause |
| --- | --- |
| `UnknownResourceId:<id>` | No definition has this ID |
| `ResourceAlreadyAssigned` | The Actor already has it |
| `InvalidResourceOverrideValue` | The override is not a finite number |
| `ResourcePropertyNonFinite:<property>` | A Property source resolved to a non-finite value |
| `ResourcePropertySeedFailed:<property>:<reason>`, `ResourcePropertyUnresolved:<property>` | The Actor's Property could not be assigned or resolved |
| `ResourceResolvedMaxLessThanResolvedMin` | The Actor's resolved maximum is below its minimum |
| `ResourceControllerDestroyed` | The Actor has been unregistered |

#### `HasResource(resourceId: string) -> boolean` {#has-resource}

Whether the Resource is assigned to this Actor.

#### `GetCurrent(resourceId: string) -> number?` {#get-current}

The current value, or `nil` if the Resource is not assigned.

#### `GetMin(resourceId: string) -> number?` {#get-min}

The resolved minimum, or `nil` if the Resource is not assigned.

#### `GetMax(resourceId: string) -> number?` {#get-max}

The resolved maximum, or `nil` if the Resource is not assigned.

#### `CanSpend(resourceId: string, amount: number) -> (boolean, string?)` {#can-spend}

Whether `Spend` would succeed with this amount. Changes nothing.

| Failure | Cause |
| --- | --- |
| `ResourceNotAssigned` | The Actor does not have the Resource |
| `InvalidResourceAmount` | The amount is negative or not a finite number |
| `InsufficientResourceValue` | Less than `amount` sits above the minimum |

#### `Spend(resourceId: string, amount: number) -> (boolean, string?)` {#spend}

Removes exactly `amount`, or nothing. Fails with the same reasons as `CanSpend`.

#### `Restore(resourceId: string, amount: number) -> (boolean, string?)` {#restore}

Adds `amount`, stopping at the maximum. Fails with `ResourceNotAssigned` or `InvalidResourceAmount`.

#### `Drain(resourceId: string, amount: number) -> (boolean, string?)` {#drain}

Removes up to `amount`, stopping at the minimum. Fails with `ResourceNotAssigned` or `InvalidResourceAmount`.

#### `SetCurrent(resourceId: string, value: number) -> (boolean, string?)` {#set-current}

Sets the current value, clamped into the bounds. Fails with `ResourceNotAssigned`, or `InvalidResourceValue` if the value is not a finite number.

#### `OnResourceAdded: Event<(Actor, string)>` {#on-resource-added}

Fires after a Resource is assigned, with the Actor and the Resource ID.

#### `OnResourceChanged: Event<(ResourceChange)>` {#on-resource-changed}

Fires after a Resource's current value, minimum or maximum changes. The payload is a `ResourceChange`:

| Field | Type | Meaning |
| --- | --- | --- |
| `actor` | `Actor` | The Actor that owns the Resource |
| `resourceId` | `string` | Which Resource changed |
| `currentOldValue`, `currentNewValue` | `number` | Current value before and after |
| `minOldValue`, `minNewValue` | `number` | Resolved minimum before and after |
| `maxOldValue`, `maxNewValue` | `number` | Resolved maximum before and after |

#### `Step(deltaTime: number) -> ()` {#step}

Infrastructure API. Advances this Actor's regeneration by `deltaTime` seconds. KRF already steps every enabled Actor automatically, so calling this adds extra regeneration.

#### `Destroy() -> ()` {#destroy}

Infrastructure API. Removes all Resource state and disconnects listeners. `ActorRuntime.UnregisterActor` calls it; game code should unregister the Actor instead.

### `ResourcesView` {#resources-view}

The client-side, read-only view of one Actor's `ClientVisible` Resources. Get it with `actorView:GetResources()`; it exists even when the Actor has no visible Resources.

| Kind | Members |
| --- | --- |
| Methods | [`HasResource`](#view-has-resource) · [`GetResource`](#view-get-resource) · [`GetCurrent`](#view-get-current) · [`GetMin`](#view-get-min) · [`GetMax`](#view-get-max) · [`GetRegenRate`](#view-get-regen-rate) · [`GetAssignedResources`](#view-get-assigned-resources) |
| Events | [`OnResourceChanged`](#view-on-resource-changed) |

#### `HasResource(resourceId: string) -> boolean` {#view-has-resource}

Whether the Actor has this visible Resource. Always `false` for `ServerOnly` Resources.

#### `GetResource(resourceId: string) -> ResourceSnapshot?` {#view-get-resource}

A frozen snapshot of the Resource right now, or `nil`. The snapshot does not update; call again for a new estimate.

| Field | Type | Meaning |
| --- | --- | --- |
| `resourceId` | `string` | The Resource ID |
| `current` | `number` | Estimated current value at the time of the call |
| `min`, `max` | `number` | Resolved bounds |
| `regenRate` | `number?` | Resolved rate per second, or `nil` without `regen` |

#### `GetCurrent(resourceId: string) -> number?` {#view-get-current}

The estimated current value, including regeneration since the last server update.

#### `GetMin(resourceId: string) -> number?` {#view-get-min}

The resolved minimum.

#### `GetMax(resourceId: string) -> number?` {#view-get-max}

The resolved maximum.

#### `GetRegenRate(resourceId: string) -> number?` {#view-get-regen-rate}

The resolved regeneration rate, or `nil` for a Resource without `regen`.

#### `GetAssignedResources() -> { ResourceSnapshot }` {#view-get-assigned-resources}

Snapshots of every visible Resource the Actor has, sorted by ID and estimated at the same moment.

#### `OnResourceChanged: Event<(ResourceViewChange)>` {#view-on-resource-changed}

Fires when the server sends new state for a Resource. It does not fire for regeneration.

| Field | Type | Meaning |
| --- | --- | --- |
| `resourceId` | `string` | Which Resource changed |
| `previous` | `ResourceSnapshot?` | State before, or `nil` if newly assigned |
| `current` | `ResourceSnapshot?` | State after |
| `source` | `"Commit" \| "Baseline"` | `"Commit"` for a server change; `"Baseline"` when the client receives the Actor's full state, such as after reconnecting |

### `ResourceRegistry` {#resource-registry}

Read-only lookup of the loaded Resource definitions. `Server.Init` loads it from your catalog.

| Member | Returns |
| --- | --- |
| `Get(resourceId: string)` | `LoadedResourceDefinition?`: the definition with defaults filled in |
| `GetAll()` | `{ LoadedResourceDefinition }` in catalog order |
| `GetAllById()` | `{ [string]: LoadedResourceDefinition }` |
| `IsLoaded()` | `boolean` |

### Definition failures {#definition-failures}

`Server.Init` reports these with `system = "Resource"`. `<Source>` stands for `ResourceMax`, `ResourceMin` or `ResourceRegenRate`.

| Reason | Cause |
| --- | --- |
| `ResourceDefinitionMustBeTable` | An entry in the catalog is not a table |
| `ResourceIdMissing`, `ResourceIdMustBeString`, `ResourceIdCannotBeEmpty` | `id` is absent, not a string, or `""` |
| `ResourceIdAlreadyRegistered` | Two definitions share an `id` |
| `ResourceVisibilityMissing`, `ResourceVisibilityMustBeString`, `ResourceVisibilityInvalid` | `visibility` is absent or not `"ClientVisible"`/`"ServerOnly"` |
| `ResourceInitialValueMustBeNumber`, `ResourceInitialValueMustBeFiniteNumber` | `initialValue` is not a finite number |
| `ResourceAutoAssignMustBeBoolean` | `autoAssign` is not a boolean |
| `ResourceMaxMissing` | `max` is absent |
| `<Source>MustBeTable` | A numeric source is not a table |
| `<Source>MustProvideValueOrPropertyName`, `<Source>CannotUseValueAndPropertyNameTogether` | A source needs exactly one of `value` and `propertyName` |
| `<Source>ValueMustBeNumber`, `<Source>ValueMustBeFiniteNumber` | `value` is not a finite number |
| `<Source>PropertyNameMustBeString`, `<Source>PropertyNameCannotBeEmpty` | `propertyName` is not a non-empty string |
| `<Source>DefaultBaseValueUnsupported` | A source has `defaultBaseValue`; put it on the Property definition |
| `UnknownPropertyId:<property>` | A source names an unregistered Property |
| `ResourceRegenMustBeTable`, `ResourceRegenRateMissing` | `regen` is not `{ rate = source }` |
| `ResourceRegenRateCannotBeNegative` | The default rate is below zero |
| `ResourceDefaultMaxLessThanDefaultMin` | With default Property values, the maximum is below the minimum |
| `ResourceInitialValueLessThanDefaultMin`, `ResourceInitialValueGreaterThanDefaultMax` | `initialValue` is outside the default bounds |

Unknown fields in a definition are ignored.
