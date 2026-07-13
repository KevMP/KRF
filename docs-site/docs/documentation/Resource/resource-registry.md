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
| Property-backed | `{ propertyName = "MaxStamina", defaultBaseValue = 100 }` | The number should follow an Actor property and active tag modifiers. |

With an attached `PropertyController`, a property-backed source seeds `defaultBaseValue` only when the Actor does not already have that property. Existing base values are preserved.

## Defaults

| Omitted field | Loaded behavior |
| --- | --- |
| `min` | Static minimum of `0` |
| `autoAssign` | `false` |
| `initialValue` | Use the Actor's resolved maximum at assignment time |

The registry can validate only default source values. Runtime assignment resolves the actual Actor properties and rejects a maximum below the minimum.

## Catalog example

```lua
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local ResourceRegistry = require(KRF.server.Resource.ResourceRegistry)
local ResourceTypes = require(KRF.server.Resource.types)

local definitions: {ResourceTypes.ResourceDefinition} = {
	{
		id = "Resource.Stamina",
		max = {
			propertyName = "MaxStamina",
			defaultBaseValue = 100,
		},
		visibility = "ClientVisible",
		autoAssign = true,
		regen = {
			rate = {
				propertyName = "StaminaRegen",
				defaultBaseValue = 12,
			},
		},
	},
	{
		id = "Resource.Guard",
		max = { value = 50 },
		visibility = "ServerOnly",
	},
}

local loaded, reason = ResourceRegistry.Load(definitions)
if not loaded then
	error(reason)
end
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
