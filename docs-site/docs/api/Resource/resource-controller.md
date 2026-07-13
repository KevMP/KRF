---
sidebar_position: 2
---

# Resource Controller

`ResourceController` owns assigned resources, current values, resolved bounds, and regeneration for one Actor. Obtain it from the Actor after controller attachment.

```lua
local resources = actor:GetController("ResourceController")
```

## Members

| Kind | Signature |
| --- | --- |
| Method | [`AddResource(resourceId: string, initialValueOverride: number?) -> (boolean, string?)`](#add-resource) |
| Method | [`HasResource(resourceId: string) -> boolean`](#has-resource) |
| Method | [`GetCurrent(resourceId: string) -> number?`](#get-current) |
| Method | [`GetMin(resourceId: string) -> number?`](#get-min) |
| Method | [`GetMax(resourceId: string) -> number?`](#get-max) |
| Method | [`SetCurrent(resourceId: string, value: number) -> (boolean, string?)`](#set-current) |
| Method | [`CanSpend(resourceId: string, amount: number) -> (boolean, string?)`](#can-spend) |
| Method | [`Spend(resourceId: string, amount: number) -> (boolean, string?)`](#spend) |
| Method | [`Restore(resourceId: string, amount: number) -> (boolean, string?)`](#restore) |
| Method | [`Drain(resourceId: string, amount: number) -> (boolean, string?)`](#drain) |
| Method | [`Step(deltaTime: number) -> ()`](#step) |
| Method | [`Destroy() -> ()`](#destroy) |
| Event | [`OnResourceAdded: Event<Actor, string>`](#on-resource-added) |
| Event | [`OnResourceChanged: Event<ResourceChange>`](#on-resource-changed) |

## Methods

### `AddResource(resourceId: string, initialValueOverride: number?) -> (boolean, string?)` {#add-resource}

Assigns one registered resource to the Actor. With an attached `PropertyController`, property-backed sources seed missing base properties, preserve existing base values, and resolve through current property modifiers. Without one, KRF uses each source's `defaultBaseValue` and the source does not update live.

When the override is omitted, KRF uses the definition's `initialValue`, then the resolved maximum when the definition also omits it.

**Returns**

- `true, nil`: the resource was assigned and `OnResourceAdded` fired.
- `false, "UnknownResourceId:<id>"`: the registry has no definition.
- `false, "ResourceAlreadyAssigned"`: the Actor already owns it.
- `false, "InvalidResourceOverrideValue"`: the override is not finite numeric input.
- `false, reason`: a property source could not resolve or resolved maximum was below minimum.

Definitions with `autoAssign = true` run this operation when the controller is constructed.

### `HasResource(resourceId: string) -> boolean` {#has-resource}

Returns whether the resource is assigned to this Actor.

### `GetCurrent(resourceId: string) -> number?` {#get-current}

Returns current value, or `nil` when unassigned.

### `GetMin(resourceId: string) -> number?` {#get-min}

Returns the current resolved minimum, or `nil` when unassigned.

### `GetMax(resourceId: string) -> number?` {#get-max}

Returns the current resolved maximum, or `nil` when unassigned.

### `SetCurrent(resourceId: string, value: number) -> (boolean, string?)` {#set-current}

Clamps a finite numeric value to the current resolved bounds.

**Returns**

- `true, nil`: the input was valid. A value that clamps to current state is a successful no-op.
- `false, "ResourceNotAssigned"`: no resource is assigned under that id.
- `false, "InvalidResourceValue"`: the value is not a finite number.

All amounts must be finite and non-negative. Invalid input returns `false, "InvalidResourceAmount"` without mutation.

### `CanSpend(resourceId: string, amount: number) -> (boolean, string?)` {#can-spend}

Checks whether `current - min >= amount`. It never mutates state.

- Returns `true, nil` when the full amount is available.
- Returns `false, "InsufficientResourceValue"` when it is not.
- Returns `false, "ResourceNotAssigned"` for an unassigned id.

### `Spend(resourceId: string, amount: number) -> (boolean, string?)` {#spend}

Pays an all-or-nothing cost. On success it subtracts the full amount; on any failure current value remains unchanged.

Zero is a successful no-op. A non-zero change fires `OnResourceChanged`.

### `Restore(resourceId: string, amount: number) -> (boolean, string?)` {#restore}

Adds the amount and clamps at the resolved maximum. Returns success even when already at maximum; no-op restores do not fire an event.

### `Drain(resourceId: string, amount: number) -> (boolean, string?)` {#drain}

Subtracts the amount and clamps at the resolved minimum. Unlike `Spend`, `Drain` succeeds with the available partial change when the requested amount crosses the minimum.

| Use | Full amount required | Lower-bound behavior |
| --- | --- | --- |
| `Spend` | Yes | Fails without mutation. |
| `Drain` | No | Clamps at minimum. |

### `Step(deltaTime: number) -> ()` {#step}

Restores `regenRate × deltaTime` for each assigned resource with a positive resolved rate. Invalid, non-finite, zero, or negative deltas are ignored.

### `Destroy() -> ()` {#destroy}

Stops automatic regeneration, disconnects property observation, clears resource state, and destroys owned events. Repeated calls are no-ops.

## Events

### `OnResourceAdded: Event<Actor, string>` {#on-resource-added}

Fires when a resource is assigned.

### `OnResourceChanged: Event<ResourceChange>` {#on-resource-changed}

Fires when a current value or resolved bound changes.

## Related

- [Resource Registry](./resource-registry)
- [Property Controller](../Property/property-controller)
- [Resource Runtime guide](/Resource/resource-runtime)
