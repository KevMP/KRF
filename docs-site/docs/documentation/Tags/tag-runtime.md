# Tag Runtime

`TagController` owns the active tags for one Actor. Each Actor has independent instances, stack counts, remaining durations, and events even when several Actors use the same definition id.

## Applying tags

`AddTag(tagId, options?)` resolves duration from the explicit option first, then the definition default. With neither, the new instance is indefinite.

| Duplicate behavior | Reapplication result |
| --- | --- |
| `Ignore` | Existing instance is preserved; no event fires. |
| `Refresh` | Existing instance resets to the newly resolved duration. |
| `Stack` below cap | New independent instance is added. |
| `Stack` at cap | Finite stack with least time remaining refreshes; oldest breaks ties. |

A refresh resets remaining duration. It never adds the new duration to time already left.

## Removing and expiring

| Transition | Scope | Event pair |
| --- | --- | --- |
| `RemoveTag` | Every instance for one id | `OnTagRemoved` → `OnTagChanged` |
| `RemoveSingleTag` | Oldest applied instance | `OnTagRemoved` → `OnTagChanged` |
| Timed expiry | The instance that reached zero | `OnTagExpired` → `OnTagChanged` |

Manual removal and expiry are deliberately distinct. Removing a timed tag never emits `OnTagExpired`; removing an inactive id fails with `TagNotActive` and emits nothing.

## Queries

| Need | Method | Shape |
| --- | --- | --- |
| Presence only | `HasTag` | Boolean |
| One row per active id | `GetActiveTags` | Aggregate stack count and longest remaining duration |
| Exact stack details | `GetTagInstances` | One snapshot per instance with duration and applied order |

`GetActiveTags()` orders ids by their oldest active instance. Returned snapshots do not expose mutable controller state.

## Timing

KRF advances timed and ticking instances automatically while the Actor is enabled.

1. Advance tick countdown and remaining duration.
2. Run a due `onTick` if the instance is still active.
3. Expire instances whose remaining duration reached zero.

A tick therefore runs before expiry when both are due in the same step. Tick-only work does not fire `OnTagChanged`, and callback errors do not stop expiry.

:::warning Keep `onTick` synchronous
Tag callbacks run inside the shared advancement pass. Do not yield or perform slow work.
:::

## Example

```lua
local tags = actor:GetController("TagController")

local added, reason = tags:AddTag("Buff.Sprint", {
	duration = 6,
})

if not added then
	warn(("Could not apply sprint: %s"):format(reason or "Unknown"))
end

local consumed = tags:RemoveSingleTag("Buff.Sprint")
```

Use typed controller acquisition in shared modules where static checking matters; see the API page for the canonical type import.

## Design rules

- Load the tag catalog before any `TagController` is constructed.
- Use `RemoveSingleTag` only when gameplay consumes one stack; otherwise use `RemoveTag`.
- Observe the specific event when add, refresh, manual removal, and expiry differ to your system.
- Read numeric outcomes from `PropertyController`, not directly from tag metadata.

## API reference

- [`TagController`](/api/Tags/tag-controller)
- [`TagRegistry`](/api/Tags/tag-registry)
- [`PropertyController`](/api/Property/property-controller)
