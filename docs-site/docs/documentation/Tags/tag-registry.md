# Tag Registry

`TagRegistry` defines the shared meaning of gameplay tags. A definition is static server-lifetime data; active instances belong to each Actor's `TagController`.

## What a definition controls

| Concern | Field |
| --- | --- |
| Identity | `id` |
| Reapplication | `duplicateBehavior`, optional `maxStacks` |
| Lifetime | optional `defaultDuration` |
| Periodic work | optional `tickInterval` and `onTick` |
| Visibility classification | `visibility` |
| Numeric effects | optional `properties` |

Load the full catalog once during startup. Validation is atomic, registration order is preserved, and a successful load cannot be replaced during that server lifetime.

## Choose duplicate behavior

| Behavior | Use when reapplication should… |
| --- | --- |
| `Ignore` | Keep the original instance unchanged. |
| `Refresh` | Keep one instance and reset its duration. |
| `Stack` | Add independent instances, optionally up to `maxStacks`. |

At the stack cap, KRF refreshes an existing instance instead of adding another. See [Tag Runtime](./tag-runtime) for exact selection and event behavior.

## Timing and ticks

- `defaultDuration` supplies a lifetime when `AddTag` does not override it.
- No duration means the instance is indefinite.
- `tickInterval` schedules `onTick` when both are present; a ticking tag does not require a duration.
- `onTick` runs synchronously during tag advancement. Keep it fast and do not yield.
- A callback failure is warned and isolated from later tag advancement.

Definitions describe timing. `TagController` owns countdown, refresh, expiry, and live instances.

## Property modifiers

Each property modifier uses one of two modes.

| Mode | Fields | Resolution |
| --- | --- | --- |
| Override | `set` only | Lowest active `set` wins. |
| Normal | Any of `add`, `multiply`, `min`, `max` | Add, multiply, then clamp. |

`set` cannot be combined with normal fields in the same modifier. Active stacks repeat additive and multiplicative effects.

Tags may name built-in or custom properties. They modify only properties already owned by `PropertyController`; they do not create custom property entries.

## Catalog example

```lua
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local TagRegistry = require(KRF.server.Tags.TagRegistry)
local TagTypes = require(KRF.server.Tags.types)

local definitions: {TagTypes.TagDefinition} = {
	{
		id = "Status.Stunned",
		defaultDuration = 1.5,
		duplicateBehavior = "Refresh",
		visibility = "ClientVisible",
		properties = {
			WalkSpeed = { set = 0 },
			JumpPower = { set = 0 },
		},
	},
	{
		id = "Buff.Sprint",
		duplicateBehavior = "Refresh",
		visibility = "ClientVisible",
		properties = {
			WalkSpeed = { add = 6, multiply = 1.15, max = 32 },
		},
	},
}

local loaded, reason = TagRegistry.Load(definitions)
if not loaded then
	error(reason)
end
```

## Design rules

- Use tags for shared gameplay state that several systems may observe.
- Keep definitions declarative; reserve `onTick` for small synchronous behavior.
- Choose `Stack` only when individual instances matter.
- Put final numeric reads in Property Runtime, not in the tag definition.

## API reference

- [`TagRegistry`](/api/Tags/tag-registry)
- [`TagController`](/api/Tags/tag-controller)
- [`PropertyController`](/api/Property/property-controller)
