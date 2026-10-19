# ResourcesView

`ResourcesView` is the immutable client facade for one Actor's assigned visible Resources.

```lua
local resources = actorView:GetResources()
-- Public contracts: KRF.client.Actor.types.ResourcesView and ResourceSnapshot.
```

## Members

| Kind | Signature |
| --- | --- |
| Method | [`HasResource(resourceId: string) -> boolean`](#has-resource) |
| Method | [`GetResource(resourceId: string) -> ResourceSnapshot?`](#resource) |
| Method | [`GetCurrent(resourceId: string) -> number?`](#current) |
| Method | [`GetMin(resourceId: string) -> number?`](#min) |
| Method | [`GetMax(resourceId: string) -> number?`](#max) |
| Method | [`GetRegenRate(resourceId: string) -> number?`](#regen-rate) |
| Method | [`GetAssignedResources() -> { ResourceSnapshot }`](#assigned) |
| Event | [`OnResourceChanged: Event<ResourceViewChange>`](#changed) |

## Methods

### `HasResource(resourceId: string) -> boolean` {#has-resource}

Returns whether the id is currently assigned in visible state; unknown, private, unassigned, and retired entries return `false`.

### `GetResource(resourceId: string) -> ResourceSnapshot?` {#resource}

Returns a new immutable point-in-time snapshot, or `nil` for an unknown, private, unassigned, or retired entry.

| Field | Value |
| --- | --- |
| `resourceId: string` | Semantic Resource id |
| `current: number` | Presentation estimate at this query's synchronized time, clamped to resolved bounds |
| `min: number` | Latest resolved minimum |
| `max: number` | Latest resolved maximum |
| `regenRate: number?` | Latest resolved rate in units per second; `nil` when no regeneration is configured |

### `GetCurrent(resourceId: string) -> number?` {#current}

Returns the current presentation estimate, or `nil` when the entry is unavailable.

### `GetMin(resourceId: string) -> number?` {#min}

Returns the latest resolved minimum, or `nil` when the entry is unavailable.

### `GetMax(resourceId: string) -> number?` {#max}

Returns the latest resolved maximum, or `nil` when the entry is unavailable.

### `GetRegenRate(resourceId: string) -> number?` {#regen-rate}

Returns the latest resolved regeneration rate, or `nil` for an unavailable entry or a Resource with no regeneration definition. A resolved zero or negative rate remains that number.

### `GetAssignedResources() -> { ResourceSnapshot }` {#assigned}

Returns an immutable array of immutable point-in-time snapshots in ascending `resourceId` order, sampled with one shared synchronized time. Empty or retired views return an empty array.

## Events

### `OnResourceChanged: Event<ResourceViewChange>` {#changed}

Fires once per differing Resource entry after authoritative replicated state installs. Initial binding and passage of local time emit no changes.

| Payload field | Meaning |
| --- | --- |
| `resourceId: string` | Changed Resource id |
| `previous: ResourceSnapshot?` | Previous immutable snapshot, or `nil` for a new assignment |
| `current: ResourceSnapshot?` | Current immutable snapshot, or `nil` when replacement removes the entry |
| `source: "Commit" \| "Baseline"` | Live commit or replacement-baseline reconciliation |

Previous and current snapshots use the same sampled client time. The payload is immutable; subscriptions survive successful replacement baselines and retire on Actor removal.

## Related

- [ResourcesView guide](/Resource/resource-views)
- [ActorView](./actor-view)
- [ActorView Registry](./actor-view-registry)
