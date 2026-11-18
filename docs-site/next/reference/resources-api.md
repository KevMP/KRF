---
title: Resources API
sidebar_position: 2
description: Signatures, payloads and failure reasons for ResourceController, ResourcesView and Resource definitions.
---

# Resources API

Exact signatures, payloads and failure reasons for Resources. [Resources](./resources) explains when to use each one.

## `ResourceDefinition` {#resource-definition}

The table each module in your Resource catalog returns. Its fields are listed under [Define a Resource](./resources#define-a-resource).

## `ResourceController` {#resource-controller}

The server-side owner of one Actor's Resources. Every Actor has one:

```lua
local resources: KRF.ResourceController? = actor:GetController("ResourceController") :: KRF.ResourceController?
```

| Kind | Members |
| --- | --- |
| Methods | [`AddResource`](#add-resource) · [`HasResource`](#has-resource) · [`GetCurrent`](#get-current) · [`GetMin`](#get-min) · [`GetMax`](#get-max) · [`CanSpend`](#can-spend) · [`Spend`](#spend) · [`Restore`](#restore) · [`Drain`](#drain) · [`SetCurrent`](#set-current) |
| Events | [`OnResourceAdded`](#on-resource-added) · [`OnResourceChanged`](#on-resource-changed) |
| Infrastructure | [`Step`](#step) · [`Destroy`](#destroy) |

### `AddResource(resourceId: string, initialValueOverride: number?) -> (boolean, string?)` {#add-resource}

Assigns a registered Resource to the Actor. The override must be a finite number, and KRF clamps it to the Actor's bounds.

| Failure | Cause |
| --- | --- |
| `UnknownResourceId:<id>` | No definition has this ID |
| `ResourceAlreadyAssigned` | The Actor already has the Resource |
| `InvalidResourceOverrideValue` | The override isn't a finite number |
| `ResourcePropertyNonFinite:<property>` | A Property source resolved to a non-finite value |
| `ResourcePropertySeedFailed:<property>:<reason>`, `ResourcePropertyUnresolved:<property>` | KRF couldn't assign or resolve the Actor's Property |
| `ResourceResolvedMaxLessThanResolvedMin` | The Actor's resolved maximum is below its minimum |
| `ResourceControllerDestroyed` | The Actor has been unregistered |

### `HasResource(resourceId: string) -> boolean` {#has-resource}

Whether the Actor has the Resource.

### `GetCurrent(resourceId: string) -> number?` {#get-current}

The current value, or `nil` if the Actor doesn't have the Resource.

### `GetMin(resourceId: string) -> number?` {#get-min}

The resolved minimum, or `nil` if the Actor doesn't have the Resource.

### `GetMax(resourceId: string) -> number?` {#get-max}

The resolved maximum, or `nil` if the Actor doesn't have the Resource.

### `CanSpend(resourceId: string, amount: number) -> (boolean, string?)` {#can-spend}

Whether `Spend` would succeed with this amount. Changes nothing.

| Failure | Cause |
| --- | --- |
| `ResourceNotAssigned` | The Actor doesn't have the Resource |
| `InvalidResourceAmount` | The amount is negative or not a finite number |
| `InsufficientResourceValue` | Less than `amount` sits above the minimum |

### `Spend(resourceId: string, amount: number) -> (boolean, string?)` {#spend}

Removes exactly `amount`, or nothing. Fails for the same reasons as `CanSpend`.

### `Restore(resourceId: string, amount: number) -> (boolean, string?)` {#restore}

Adds `amount` and stops at the maximum. Fails with `ResourceNotAssigned` or `InvalidResourceAmount`.

### `Drain(resourceId: string, amount: number) -> (boolean, string?)` {#drain}

Removes up to `amount` and stops at the minimum. Fails with `ResourceNotAssigned` or `InvalidResourceAmount`.

### `SetCurrent(resourceId: string, value: number) -> (boolean, string?)` {#set-current}

Sets the current value, clamped into the bounds. Fails with `ResourceNotAssigned`, or with `InvalidResourceValue` if the value isn't a finite number.

### `OnResourceAdded: Event<(Actor, string)>` {#on-resource-added}

Fires after a Resource is assigned, with the Actor and the Resource ID.

### `OnResourceChanged: Event<(ResourceChange)>` {#on-resource-changed}

Fires after a Resource's current value, minimum or maximum changes, including on regeneration steps. A change to the regeneration rate alone doesn't fire it. The payload is a `ResourceChange`:

| Field | Type | Meaning |
| --- | --- | --- |
| `actor` | `Actor` | The Actor that owns the Resource |
| `resourceId` | `string` | The Resource that changed |
| `currentOldValue`, `currentNewValue` | `number` | Current value before and after |
| `minOldValue`, `minNewValue` | `number` | Resolved minimum before and after |
| `maxOldValue`, `maxNewValue` | `number` | Resolved maximum before and after |

### `Step(deltaTime: number) -> ()` {#step}

Infrastructure API. Advances this Actor's regeneration by `deltaTime` seconds. KRF already steps every enabled Actor, so a call adds extra regeneration.

### `Destroy() -> ()` {#destroy}

Infrastructure API. Removes all Resource state and disconnects listeners. `ActorRuntime.UnregisterActor` calls it; game code unregisters the Actor instead.

## `ResourcesView` {#resources-view}

The client's read-only view of one Actor's `ClientVisible` Resources. It exists even when the Actor has no visible Resources:

```lua
local resources: KRF.ResourcesView = actorView:GetResources()
```

| Kind | Members |
| --- | --- |
| Methods | [`HasResource`](#view-has-resource) · [`GetResource`](#view-get-resource) · [`GetCurrent`](#view-get-current) · [`GetMin`](#view-get-min) · [`GetMax`](#view-get-max) · [`GetRegenRate`](#view-get-regen-rate) · [`GetAssignedResources`](#view-get-assigned-resources) |
| Events | [`OnResourceChanged`](#view-on-resource-changed) |

### `HasResource(resourceId: string) -> boolean` {#view-has-resource}

Whether the Actor has this visible Resource. Always `false` for a `ServerOnly` Resource.

### `GetResource(resourceId: string) -> ResourceSnapshot?` {#view-get-resource}

A frozen snapshot of the Resource at the moment of the call, or `nil`. The snapshot doesn't update; call again for a new estimate.

| Field | Type | Meaning |
| --- | --- | --- |
| `resourceId` | `string` | The Resource ID |
| `current` | `number` | Estimated current value at the time of the call |
| `min`, `max` | `number` | Resolved bounds |
| `regenRate` | `number?` | Resolved rate per second, or `nil` without `regen` |

### `GetCurrent(resourceId: string) -> number?` {#view-get-current}

The estimated current value, including regeneration since the last server update.

### `GetMin(resourceId: string) -> number?` {#view-get-min}

The resolved minimum.

### `GetMax(resourceId: string) -> number?` {#view-get-max}

The resolved maximum.

### `GetRegenRate(resourceId: string) -> number?` {#view-get-regen-rate}

The resolved regeneration rate, or `nil` for a Resource without `regen`.

### `GetAssignedResources() -> { ResourceSnapshot }` {#view-get-assigned-resources}

Snapshots of every visible Resource the Actor has, sorted by ID and estimated at the same moment.

### `OnResourceChanged: Event<(ResourceViewChange)>` {#view-on-resource-changed}

Fires when the server sends new state for a Resource. Regeneration doesn't fire it.

| Field | Type | Meaning |
| --- | --- | --- |
| `resourceId` | `string` | The Resource that changed |
| `previous` | `ResourceSnapshot?` | State before, or `nil` if newly assigned |
| `current` | `ResourceSnapshot?` | State after |
| `source` | `"Commit" \| "Baseline"` | `"Commit"` for a server change; `"Baseline"` when the client receives the Actor's full state, such as after reconnecting |

## `ResourceRegistry` {#resource-registry}

Read-only lookup of the loaded Resource definitions. `Server.Init` loads it from your catalog.

| Member | Returns |
| --- | --- |
| `Get(resourceId: string)` | `LoadedResourceDefinition?`, the definition with defaults filled in |
| `GetAll()` | `{ LoadedResourceDefinition }` in catalog order |
| `GetAllById()` | `{ [string]: LoadedResourceDefinition }` |
| `IsLoaded()` | `boolean` |

## Definition failures {#definition-failures}

`Server.Init` reports these with `system = "Resource"`. In the table, `<Source>` stands for `ResourceMax`, `ResourceMin` or `ResourceRegenRate`.

| Reason | Cause |
| --- | --- |
| `ResourceDefinitionMustBeTable` | An entry in the catalog isn't a table |
| `ResourceIdMissing`, `ResourceIdMustBeString`, `ResourceIdCannotBeEmpty` | `id` is absent, not a string, or `""` |
| `ResourceIdAlreadyRegistered` | Two definitions share an `id` |
| `ResourceVisibilityMissing`, `ResourceVisibilityMustBeString`, `ResourceVisibilityInvalid` | `visibility` is absent or isn't `"ClientVisible"` or `"ServerOnly"` |
| `ResourceInitialValueMustBeNumber`, `ResourceInitialValueMustBeFiniteNumber` | `initialValue` isn't a finite number |
| `ResourceAutoAssignMustBeBoolean` | `autoAssign` isn't a boolean |
| `ResourceMaxMissing` | `max` is absent |
| `<Source>MustBeTable` | A numeric source isn't a table |
| `<Source>MustProvideValueOrPropertyName`, `<Source>CannotUseValueAndPropertyNameTogether` | A source needs exactly one of `value` and `propertyName` |
| `<Source>ValueMustBeNumber`, `<Source>ValueMustBeFiniteNumber` | `value` isn't a finite number |
| `<Source>PropertyNameMustBeString`, `<Source>PropertyNameCannotBeEmpty` | `propertyName` isn't a non-empty string |
| `<Source>DefaultBaseValueUnsupported` | A source has `defaultBaseValue`; put it on the Property definition |
| `UnknownPropertyId:<property>` | A source names an unregistered Property |
| `ResourceRegenMustBeTable`, `ResourceRegenRateMissing` | `regen` isn't `{ rate = source }` |
| `ResourceRegenRateCannotBeNegative` | The default rate is below zero |
| `ResourceDefaultMaxLessThanDefaultMin` | With default Property values, the maximum is below the minimum |
| `ResourceInitialValueLessThanDefaultMin`, `ResourceInitialValueGreaterThanDefaultMax` | `initialValue` is outside the default bounds |

KRF ignores unknown fields in a definition.
