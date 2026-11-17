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
local KRF = require(ReplicatedStorage.Packages.KRF)
type Actor = KRF.Actor
type PropertyController = KRF.PropertyController

local function increaseWalkSpeed(actor: Actor): number
	local properties = actor:GetController("PropertyController") :: PropertyController
	local baseWalkSpeed = properties:GetBaseProperty("WalkSpeed") :: number

	properties:SetBaseProperty("WalkSpeed", baseWalkSpeed + 2)
	return properties:GetResolvedProperty("WalkSpeed") :: number
end
```

New controllers require a loaded [Property catalog](./property-registry). By default, they auto-assign:

| Property | Base value |
| --- | --- |
| `WalkSpeed` | `16` |
| `JumpPower` | `50` |

Only registered IDs can be written. `SetBaseProperty` creates an Actor-local record on the first write to a registered ID. Unknown IDs return `UnknownPropertyId`; malformed IDs return `InvalidPropertyId`, before mutation or events. Registration alone does not make `HasProperty` true. A Tag modifier alone never assigns a Property.

Use `autoAssign` or `RegisterActor(model, { properties = { Defense = 20 } })` for silent initial values. Overrides are installed before dependent controller factories, including ResourceController. Both paths resolve already-active Tags.

## Tag resolution

`PropertyController` reads active definitions from `TagController`.

| Mode | Result |
| --- | --- |
| Any active `set` | Lowest `set` wins; all normal modifiers are ignored. |
| Normal modifiers | Add first, multiply second, then clamp to active min and max. |

Stacks repeat their `add` and `multiply` contribution. The highest active minimum and lowest active maximum form the clamp.

Attach `TagController` before `PropertyController`. Already-active Tags apply at construction. Later Tag changes update resolved values before consumer callbacks run.

## Changes

| Cause | Base event | Resolved event | Combined event |
| --- | --- | --- | --- |
| Base changes; resolved changes | Yes | Yes | Yes |
| Base changes; resolved stays equal | Yes | No | Yes |
| Tag changes resolved value | No | Yes | Yes |
| Write or recompute is a no-op | No | No | No |

This lets systems subscribe at the narrowest level they need. A movement adapter normally observes resolved changes; a progression system may care about base changes.

Property notifications report net changes and are journaled in commit order. If a lifecycle or Tag listener synchronously performs another mutation that dispatches Property notifications, older pending notifications are issued first. Nested operations remain synchronous. Queries always return current committed state, even when an event payload describes an older transition.

## Design rules

- Do not store current resource meters as properties. Resources own their own current values.
- Do not read base values for calculations that should include buffs and debuffs.
- Register custom Properties before assigning them with `SetBaseProperty` before expecting tag modifiers to affect them.
- Keep non-numeric Actor state in its owning system.

## API reference

- [`PropertyController`](/api/Property/property-controller)
- [`TagRegistry`](/api/Tags/tag-registry)
- [`TagController`](/api/Tags/tag-controller)
