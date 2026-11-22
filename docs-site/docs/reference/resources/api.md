---
title: Resources API
sidebar_position: 2
description: Signatures, payloads and failure reasons for ResourceController, ResourcesView and Resource definitions.
---

# Resources API

Server methods use the Actor's ResourceController. Client methods use its ResourcesView and never mutate server state. See [Resources](./guide) for assignment, costs and regeneration.

## `ResourceDefinition` {#resource-definition}

Pass definitions through `Server.Init({ resources = ... })`.

| Field | Type | Default / constraint |
| --- | --- | --- |
| `id` | `string` | Required unique, non-empty ID |
| `max` | Numeric source | Required |
| `min` | Numeric source | `{ value = 0 }` |
| `initialValue` | `number?` | Actor's resolved maximum on assignment; an authored value must fit default bounds |
| `visibility` | `"ClientVisible" \| "ServerOnly"` | Required; client-visible means all clients |
| `autoAssign` | `boolean?` | `false`; if true, attempt assignment during Actor registration |
| `regen` | `{ rate: NumericSource }?` | No automatic regeneration |

A numeric source is exactly one of `{ value: number }` or `{ propertyName: string }`. Constants must be finite; named Properties must be registered. Put `defaultBaseValue` on the Property definition, not the source. The default regeneration rate cannot be negative.

An `AddResource` override takes precedence over `initialValue`; both are clamped to the Actor's current bounds on assignment. An invalid definition rejects startup with `system = "Resource"`; see [definition failures](#definition-failures). Unknown fields are currently ignored. Startup copies and freezes the normalized definition, including its sources; editing the author's table later doesn't change the loaded contract.

Definition validation uses Property defaults. An individual Actor's overrides or active modifiers can still make assignment fail. Automatic assignment warns and continues without that Resource; it does not turn an ordinary AddResource refusal into a failed Actor registration.

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

Boolean-returning methods return `true, nil` on success, including no-ops, or `false, reason` for a refusal. Amounts may be zero. Queries return nil/false after teardown because the assigned records are cleared. Internal publication failures can throw after authority has changed; they do not roll back that mutation.

### `AddResource(resourceId: string, initialValueOverride: number?) -> (boolean, string?)` {#add-resource}

Assigns a registered Resource to the Actor. The override must be a finite number, and KRF clamps it to the Actor's bounds.

Property-backed sources seed any missing Property from its registered default, preserving an existing base value. A failed assignment creates no Resource record, but Properties already seeded while resolving its sources can remain assigned.

| Failure | Cause |
| --- | --- |
| `UnknownResourceId:<id>` | No definition has this ID |
| `ResourceAlreadyAssigned` | The Actor already has the Resource |
| `InvalidResourceOverrideValue` | The override isn't a finite number |
| `ResourcePropertyNonFinite:<property>` | A Property source resolved to a non-finite value |
| `ResourcePropertySeedFailed:<property>:<reason>`, `ResourcePropertyUnresolved:<property>` | KRF couldn't assign or resolve the Actor's Property |
| `ResourceResolvedMaxLessThanResolvedMin` | The Actor's resolved maximum is below its minimum |
| `ResourceControllerDestroyed` | The Controller has been destroyed |

### `HasResource(resourceId: string) -> boolean` {#has-resource}

Whether the Actor has the Resource.

### `GetCurrent(resourceId: string) -> number?` {#get-current}

The current value, or `nil` if the Actor doesn't have the Resource.

### `GetMin(resourceId: string) -> number?` {#get-min}

The resolved minimum, or `nil` if the Actor doesn't have the Resource.

### `GetMax(resourceId: string) -> number?` {#get-max}

The resolved maximum, or `nil` if the Actor doesn't have the Resource.

### `CanSpend(resourceId: string, amount: number) -> (boolean, string?)` {#can-spend}

Checks assignment, a finite nonnegative amount and available value above the minimum. Changes nothing. It checks affordability; a later Spend can still fail if its arithmetic produces a non-finite result.

| Failure | Cause |
| --- | --- |
| `ResourceNotAssigned` | The Actor doesn't have the Resource |
| `InvalidResourceAmount` | The amount is negative or not a finite number |
| `InsufficientResourceValue` | Less than `amount` sits above the minimum |

### `Spend(resourceId: string, amount: number) -> (boolean, string?)` {#spend}

Removes exactly `amount`, or nothing. Fails for the same reasons as `CanSpend`, or `InvalidResourceValue` if the computed value is non-finite.

### `Restore(resourceId: string, amount: number) -> (boolean, string?)` {#restore}

Adds `amount` and stops at the maximum. Fails with `ResourceNotAssigned`, `InvalidResourceAmount`, or `InvalidResourceValue` if addition overflows. Finiteness is checked before clamping.

### `Drain(resourceId: string, amount: number) -> (boolean, string?)` {#drain}

Removes up to `amount` and stops at the minimum. Fails with `ResourceNotAssigned`, `InvalidResourceAmount`, or `InvalidResourceValue` if subtraction overflows. Finiteness is checked before clamping.

### `SetCurrent(resourceId: string, value: number) -> (boolean, string?)` {#set-current}

Sets the current value, clamped into the bounds. Fails with `ResourceNotAssigned`, or with `InvalidResourceValue` if the value isn't a finite number.

### `OnResourceAdded: Event<(Actor, string)>` {#on-resource-added}

Fires after a Resource is assigned, with the Actor and the Resource ID.

Assignment emits Added, not Changed. Automatic assignments happen during Controller construction, before the Actor's registration event, so later consumers must query initial state rather than expect those additions to replay.

### `OnResourceChanged: Event<(ResourceChange)>` {#on-resource-changed}

Fires after a Resource's current value, minimum or maximum changes, including on regeneration steps. A change to the regeneration rate alone doesn't fire it. No-op writes emit nothing. Property recomputation and Action payment batches install all affected state first and issue net Resource changes in ID order. Separate calls and multi-meter regeneration are not one such batch. The payload is a `ResourceChange`:

| Field | Type | Meaning |
| --- | --- | --- |
| `actor` | `Actor` | The Actor that owns the Resource |
| `resourceId` | `string` | The Resource that changed |
| `currentOldValue`, `currentNewValue` | `number` | Current value before and after |
| `minOldValue`, `minNewValue` | `number` | Resolved minimum before and after |
| `maxOldValue`, `maxNewValue` | `number` | Resolved maximum before and after |

### `Step(deltaTime: number) -> ()` {#step}

Infrastructure API. Advances this Actor's positive regeneration rates by `deltaTime` seconds. Invalid, non-finite or nonpositive deltas do nothing. KRF already steps enabled Actors automatically with fixed 0.1-second deltas, at most once per Heartbeat; a manual call adds extra regeneration and does not check the Actor's enabled flag.

### `Destroy() -> ()` {#destroy}

Infrastructure API. Idempotently removes all Resource state, stops automatic advancement and disconnects listeners without emitting removal events. `ActorRuntime.UnregisterActor` calls it; game code unregisters the Actor instead.

## `ResourcesView` {#resources-view}

The client's read-only view of one Actor's `ClientVisible` Resources. It exists even when the Actor has no visible Resources:

```lua
local resources: KRF.ResourcesView = actorView:GetResources()
```

| Kind | Members |
| --- | --- |
| Methods | [`HasResource`](#view-has-resource) · [`GetResource`](#view-get-resource) · [`GetCurrent`](#view-get-current) · [`GetMin`](#view-get-min) · [`GetMax`](#view-get-max) · [`GetRegenRate`](#view-get-regen-rate) · [`GetAssignedResources`](#view-get-assigned-resources) |
| Events | [`OnResourceChanged`](#view-on-resource-changed) |

Every scalar query except HasResource returns nil for an absent or hidden Resource; HasResource returns false and GetAssignedResources returns an empty array. Retained views stop exposing state when their owning ActorView becomes unavailable.

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

The estimated current value, including positive regeneration since its server anchor, clamped to the bounds. Zero or negative rates do not reduce the estimate.

### `GetMin(resourceId: string) -> number?` {#view-get-min}

The resolved minimum.

### `GetMax(resourceId: string) -> number?` {#view-get-max}

The resolved maximum.

### `GetRegenRate(resourceId: string) -> number?` {#view-get-regen-rate}

The resolved regeneration rate, or `nil` for a Resource without `regen`.

### `GetAssignedResources() -> { ResourceSnapshot }` {#view-get-assigned-resources}

Snapshots of every visible Resource the Actor has, sorted by ID and estimated at the same moment.

### `OnResourceChanged: Event<(ResourceViewChange)>` {#view-on-resource-changed}

Reports changed Resource anchors installed from the server, in Resource ID order. Local regeneration estimates don't fire it. It does not promise one callback per server mutation: state updates may coalesce, and creating a view with initial state emits no historical changes. Subscribe and separately query current state when attaching a consumer.

The event's previous/current snapshots use the same query time, including estimated regeneration. A changed anchor can produce a notification even when its current estimate equals the previous estimate.

| Field | Type | Meaning |
| --- | --- | --- |
| `resourceId` | `string` | The Resource that changed |
| `previous` | `ResourceSnapshot?` | State before, or `nil` if newly assigned |
| `current` | `ResourceSnapshot?` | State after |
| `source` | `"Commit" \| "Baseline"` | `"Commit"` for a live update; `"Baseline"` for replacement current truth, such as recovery |

## `ResourceRegistry` {#resource-registry}

Read-only lookup of the loaded Resource definitions. `Server.Init` loads it from your catalog.

| Member | Returns |
| --- | --- |
| `Get(resourceId: string)` | `LoadedResourceDefinition?`, the definition with defaults filled in |
| `GetAll()` | `{ LoadedResourceDefinition }` in catalog order |
| `GetAllById()` | `{ [string]: LoadedResourceDefinition }` |
| `IsLoaded()` | `boolean` |

Call these methods with dot syntax on `KRF.ResourceRegistry`. Definitions and returned collections are frozen; before loading, lookups return nil/empty collections. `Load` belongs to startup infrastructure, not live catalog replacement.

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

