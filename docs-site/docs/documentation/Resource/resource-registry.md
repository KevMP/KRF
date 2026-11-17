# Resource Registry

`ResourceRegistry` owns the static catalog for Actor-scoped meters such as stamina, mana, guard, heat, or focus. Definitions describe how live resources should be created; they do not contain an Actor's current value.

## Definition and runtime state

| Concern | Owner |
| --- | --- |
| Id, visibility, numeric sources, initial value, auto-assignment, regeneration metadata | `ResourceRegistry` |
| Assignment, current value, resolved bounds, spending, draining, restoration, regeneration | `ResourceController` |
| Numeric properties used by property-backed sources | `PropertyController` |

Load the catalog once during server startup. Validation is atomic: one invalid definition rejects the full call, and a successful catalog cannot be replaced during that server lifetime.

## Numeric sources

Minimum, maximum, and regeneration rate each use one source mode.

| Source | Shape | Choose it when… |
| --- | --- | --- |
| Static | `{ value = 100 }` | Every Actor uses the same authored number. |
| Property-backed | `{ propertyName = "MaxStamina" }` | The number should follow an Actor property and active tag modifiers. |

With an attached `PropertyController`, a property-backed source seeds the registered Property default only when the Actor does not already have that property. Existing base values are preserved.

Without a PropertyController, sources resolve from the same registry defaults.

## Defaults

| Omitted field | Loaded behavior |
| --- | --- |
| `min` | Static minimum of `0` |
| `autoAssign` | `false` |
| `initialValue` | Use the Actor's resolved maximum at assignment time |

Every backing Property must be registered. Defaults come only from [PropertyRegistry](../Property/property-registry); Resource `defaultBaseValue` is rejected. The registry validates bounds, initial values and nonnegative regeneration against these defaults. Runtime assignment resolves the actual Actor properties and rejects a maximum below the minimum.

## Client visibility

`ClientVisible` definitions contribute ids to the built-in Resource protocol. Assigned entries appear in [ResourcesView](./resource-views); registered but unassigned definitions create no Actor state. `ServerOnly` definitions and their ids remain outside client metadata and state. When no visible definitions exist, the protocol omits the Resource domain and every ActorView still provides an empty ResourcesView.

## Catalog example

Declare `MaxStamina = 100` and `StaminaRegen = 12` in the [Property catalog](../Property/property-registry) for this example.

This ModuleScript returns definitions for the `resources` field of your [game configuration](../initializing-krf). Game startup loads the catalog; the module does not call `ResourceRegistry.Load`.

```lua
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = require(ReplicatedStorage.Packages.KRF)

local definitions: { KRF.ResourceDefinition } = {
	{
		id = "Resource.Stamina",
		max = {
			propertyName = "MaxStamina",
		},
		visibility = "ServerOnly",
		autoAssign = true,
		regen = {
			rate = {
				propertyName = "StaminaRegen",
			},
		},
	},
	{
		id = "Resource.Guard",
		max = { value = 50 },
		visibility = "ServerOnly",
	},
}

return definitions
```

## Design rules

- Load definitions before any `ResourceController` is constructed.
- Use `autoAssign` only for resources every Actor with that controller should own.
- Keep current values out of definitions; they belong to each Actor.
- Use property-backed sources only when live Actor modifiers should affect the number.

## API reference

- [`ResourceRegistry`](/api/Resource/resource-registry)
- [`ResourceController`](/api/Resource/resource-controller)
- [`PropertyController`](/api/Property/property-controller)
