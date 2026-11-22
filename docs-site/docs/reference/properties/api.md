---
title: Properties API
---

# Properties API

Property definitions and Controllers are server-side. Import public types from the package entrypoint; client consumers read selected replicated state through [ActorViews](../actors/client-views).

## PropertyDefinition

| Field | Type | Default / constraint |
| --- | --- | --- |
| `id` | `string` | Required non-empty ID |
| `defaultBaseValue` | `number` | Required finite number |
| `autoAssign` | `boolean?` | `false` for custom Properties; built-in WalkSpeed and JumpPower default to `true` |

WalkSpeed defaults to 16 and JumpPower to 50. Game definitions can replace either built-in definition once in their catalog, including `autoAssign = false`. Omitted `autoAssign` still defaults to true for those two IDs. Unknown definition fields reject startup. KRF copies and freezes the loaded definitions; caller edits after startup do not change them.

## PropertyController

```lua
local properties = actor:GetController("PropertyController") :: KRF.PropertyController
```

### SetBaseProperty

```lua
properties:SetBaseProperty(propertyName: string, value: number) -> (boolean, string?)
```

Creates the Actor-local record on the first write to a registered ID, or changes its base value. `propertyName` is the definition's ID, not a Roblox Instance property name. The write resolves active Tag modifiers before notifications. Returns `true, nil` for success, including a no-op.

| Failure | Cause |
| --- | --- |
| `PropertyControllerDestroyed` | Controller has been torn down |
| `InvalidPropertyId` | ID isn't a non-empty string |
| `UnknownPropertyId` | No registered definition |
| `InvalidPropertyValue` | Value isn't a number |

Definition defaults and registration overrides are checked for finiteness. The current SetBaseProperty implementation checks the runtime value's numeric type only; callers should supply finite values. A dependent Resource retains its last valid bounds/rate if resolution becomes invalid.

The base and resolved values commit before notification. A failure in a framework-private commit or publication observer can raise through this call after the write; it is not a `false, reason` result and does not roll back the Property change. Required notification work is still attempted before the error propagates.

### Queries

| Signature | Return |
| --- | --- |
| `properties:GetBaseProperty(propertyName: string) -> number?` | Base value, or `nil` if unassigned |
| `properties:GetResolvedProperty(propertyName: string) -> number?` | Resolved value, or `nil` if unassigned |
| `properties:GetResolvedProperties() -> { [string]: number }` | Frozen snapshot of assigned resolved values |
| `properties:HasProperty(propertyName: string) -> boolean` | Whether this Actor has a record |

Unknown or unassigned IDs query nil/false. Registering a definition does not assign it unless `autoAssign` is enabled. Registration overrides and Resource source seeding are the other assignment paths. No public method removes an assigned Property.

### Resolved values

Without an active `set` modifier:

```text
resolved = (base + sum(add * stackCount)) * product(multiply ^ stackCount)
```

The highest active `min` clamps the result upward, then the lowest active `max` clamps it downward. A conflicting maximum therefore wins. If any active modifier supplies `set`, the lowest set value wins and bypasses all additions, multiplications and clamps. See [Tag modifier declarations](../tags/api#property-modifiers) for valid field combinations.

### Events

| Event | Arguments |
| --- | --- |
| `OnBasePropertyChanged` | `(actor: Actor, propertyName: string, oldValue: number?, newValue: number)` |
| `OnResolvedPropertyChanged` | Same shape, using resolved values |
| `OnPropertyChanged` | One `PropertyChange` record |

`PropertyChange` contains `actor`, `propertyName`, `oldBaseValue: number?`, `newBaseValue: number`, `oldResolvedValue: number?`, `newResolvedValue: number`. Old values are `nil` on first assignment. Silent initial assignment during Actor registration doesn't emit these write events.

Changing a base value can emit a base and combined event without a resolved event if an active override keeps the resolved value unchanged. Tag-only changes emit resolved and combined events when resolution changes. No-ops emit nothing.

For one change, notifications are issued in this order: base when changed, resolved when changed, then combined. A Tag mutation recomputes affected assigned Properties in Property ID order before their notifications. Public callbacks can reenter or yield; listener completion is not a barrier. Queries read installed state even when an event payload describes an earlier transition.

`properties:Destroy() -> ()` disconnects observers and destroys its Events. It is idempotent and emits no synthetic Property changes. Subsequent writes return `PropertyControllerDestroyed`; the current implementation retains stored values, so a retained Controller's queries can still return its final numbers. ActorRuntime owns normal teardown; game code unregisters the Actor and releases its Controller references.

## PropertyRegistry

| Signature | Return |
| --- | --- |
| `KRF.PropertyRegistry.Get(id: string) -> PropertyDefinition?` | Frozen loaded definition or `nil` |
| `KRF.PropertyRegistry.GetAll() -> { PropertyDefinition }` | Frozen array: WalkSpeed and JumpPower first, then custom definitions in catalog order |
| `KRF.PropertyRegistry.GetAllById() -> { [string]: PropertyDefinition }` | Frozen definition map |
| `KRF.PropertyRegistry.IsLoaded() -> boolean` | Installation state |

Before catalog publication, queries return nil or empty collections and IsLoaded returns false. `Load`, `Prepare` and `Publish` are startup infrastructure. Use `Server.Init` for authoring catalogs.

### Definition failures

Startup reports `system = "Property"`:

| Reasons | Cause |
| --- | --- |
| `PropertyDefinitionsMustBeTable`, `PropertyDefinitionsMustBeArray`, `PropertyDefinitionMustBeTable` | Invalid catalog or entry shape |
| `InvalidPropertyId`, `PropertyIdAlreadyRegistered` | Invalid or repeated ID |
| `PropertyDefaultBaseValueMustBeFiniteNumber` | Missing, non-numeric or non-finite default |
| `PropertyAutoAssignMustBeBoolean`, `PropertyDefinitionFieldUnsupported` | Invalid flag or unsupported field |
| `PropertyDefinitionsAlreadyLoaded` | Catalog already installed |

See [Properties](./guide), [Tag modifiers](../tags/api#property-modifiers) and [initial Property overrides](../actors/api#registeractor).
