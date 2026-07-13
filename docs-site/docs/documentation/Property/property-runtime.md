# Property Runtime

`PropertyController` owns numeric properties for one Actor. It separates the value game code supplies from the value gameplay systems should consume.

## Base and resolved values

| Value | Meaning | Typical use |
| --- | --- | --- |
| Base | Number set directly by game code | Level progression, equipment, permanent stat changes |
| Resolved | Base after active tag modifiers | Movement, combat calculations, resource bounds |

Most gameplay decisions should read the resolved value. Write the base value when the Actor's underlying stat changes.

```lua
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local ActorTypes = require(KRF.server.Actor.types)
local PropertyTypes = require(KRF.server.Property.types)
type Actor = ActorTypes.Actor
type PropertyController = PropertyTypes.PropertyController

local function increaseWalkSpeed(actor: Actor): number
	local properties = actor:GetController("PropertyController") :: PropertyController
	local baseWalkSpeed = properties:GetBaseProperty("WalkSpeed") :: number

	properties:SetBaseProperty("WalkSpeed", baseWalkSpeed + 2)
	return properties:GetResolvedProperty("WalkSpeed") :: number
end
```

New controllers start with:

| Property | Base value |
| --- | --- |
| `WalkSpeed` | `16` |
| `JumpPower` | `50` |

Setting a new property name creates custom numeric state. A tag modifier alone never creates that entry.

## Tag resolution

`PropertyController` reads active definitions from `TagController`.

| Mode | Result |
| --- | --- |
| Any active `set` | Lowest `set` wins; all normal modifiers are ignored. |
| Normal modifiers | Add first, multiply second, then clamp to active min and max. |

Stacks repeat their `add` and `multiply` contribution. The highest active minimum and lowest active maximum form the clamp.

Attach `TagController` before `PropertyController`. The property controller applies already-active tags at construction and observes later add, refresh, removal, and expiry events.

## Changes

| Cause | Base event | Resolved event | Combined event |
| --- | --- | --- | --- |
| Base changes; resolved changes | Yes | Yes | Yes |
| Base changes; resolved stays equal | Yes | No | Yes |
| Tag changes resolved value | No | Yes | Yes |
| Write or recompute is a no-op | No | No | No |

This lets systems subscribe at the narrowest level they need. A movement adapter normally observes resolved changes; a progression system may care about base changes.

## Design rules

- Do not store current resource meters as properties. Resources own their own current values.
- Do not read base values for calculations that should include buffs and debuffs.
- Create custom properties explicitly with `SetBaseProperty` before expecting tag modifiers to affect them.
- Keep non-numeric Actor state in its owning system.

## API reference

- [`PropertyController`](/api/Property/property-controller)
- [`TagRegistry`](/api/Tags/tag-registry)
- [`TagController`](/api/Tags/tag-controller)
