# Property Runtime

`PropertyController` is KRF's per-actor runtime surface for numeric gameplay properties.

Use it when game code needs to read or change values such as movement stats or other numeric properties that belong to one live actor.

## What this is

KRF stores properties per actor.

Each property has:

* a **base value**, which is the value game code sets directly
* a **resolved value**, which is the value other systems should read when they need the actor's current final number

This separation gives KRF one place to own numeric property state instead of having unrelated systems mutate Humanoid values or ad hoc tables directly.

## What this owns

`PropertyController` owns:

* built in numeric properties on an actor
* custom numeric properties created by game code
* base value updates
* resolved value reads
* property change events for runtime observers

## What this does not own

`PropertyController` does not own:

* registering or unregistering actors
* defining tag catalogs
* deciding what a custom property means in combat, UI, or progression
* non-numeric property data

## Canonical flow

`PropertyController` is a KRF owned controller on a live actor.

The normal flow is:

1. Get the actor's `PropertyController`.
2. Set base values when your game changes the actor's underlying stat.
3. Read resolved values when another system needs the actor's current number.
4. Observe property events only when another runtime system must react immediately.

KRF currently includes two built in properties on every actor:

* `WalkSpeed`, default `16`
* `JumpPower`, default `50`

Game code may also create custom numeric properties by setting a base value for a new property name.

## Example

```lua
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local ActorTypes = require(KRF.server.Actor.types)
local PropertyTypes = require(KRF.server.Property.types)

type Actor = ActorTypes.Actor
type PropertyController = PropertyTypes.PropertyController

local function getPropertyController(actor: Actor): PropertyController
	return actor:GetController("PropertyController") :: PropertyController
end

local function applyLevelUp(actor: Actor): ()
	local propertyController: PropertyController = getPropertyController(actor)
	local currentWalkSpeed: number = propertyController:GetBaseProperty("WalkSpeed") :: number

	propertyController:SetBaseProperty("WalkSpeed", currentWalkSpeed + 2)
	propertyController:SetBaseProperty("CriticalChance", 10)
end
```

## Common mistakes

* Reading base values when another system really needs the actor's current final number. Prefer resolved values for runtime decisions.
* Storing numeric actor state in unrelated tables when the value belongs to the actor lifecycle.
* Treating a custom property name as a gameplay rule by itself. KRF stores the number, but your game still decides how to use it.
* Using non-numeric values. `PropertyController` only accepts numbers.

## Related concepts

Read [Actor Runtime](../Actor/actor-runtime) for the actor lifecycle that creates and tears down the controllers.

Read [Tag Registry](../Tags/tag-registry) for tag-defined property modifiers such as `set`, `add`, `multiply`, `min`, and `max`.
