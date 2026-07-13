---
sidebar_position: 2
---

# Tag Controller

`TagController` owns active tag instances for one Actor. Obtain it from the Actor after controller attachment.

```lua
local tags = actor:GetController("TagController")
```

## Members

| Kind | Signature |
| --- | --- |
| Method | [`AddTag(tagId: string, options: AddTagOptions?) -> (boolean, string?)`](#add-tag) |
| Method | [`RemoveTag(tagId: string) -> (boolean, string?)`](#remove-tag) |
| Method | [`RemoveSingleTag(tagId: string) -> (boolean, string?)`](#remove-single-tag) |
| Method | [`HasTag(tagId: string) -> boolean`](#has-tag) |
| Method | [`GetActiveTags() -> {ActiveTagSnapshot}`](#get-active-tags) |
| Method | [`GetTagInstances(tagId: string) -> {TagInstanceSnapshot}`](#get-tag-instances) |
| Method | [`Destroy() -> ()`](#destroy) |
| Event | [`OnTagAdded: Event<Actor, string>`](#on-tag-added) |
| Event | [`OnTagRefreshed: Event<Actor, string>`](#on-tag-refreshed) |
| Event | [`OnTagRemoved: Event<Actor, string>`](#on-tag-removed) |
| Event | [`OnTagExpired: Event<Actor, string>`](#on-tag-expired) |
| Event | [`OnTagChanged: Event<Actor, string>`](#on-tag-changed) |

## Methods

### `AddTag(tagId: string, options: AddTagOptions?) -> (boolean, string?)` {#add-tag}

Adds, refreshes, stacks, or ignores an application according to the registered definition.

**Returns**

- `true, nil`: the request was accepted, including an ignored reapplication.
- `false, "UnknownTagId:<id>"`: the registry has no definition.
- `false, "TagDurationMustBePositive"`: explicit duration is zero or negative.

### `RemoveTag(tagId: string) -> (boolean, string?)` {#remove-tag}

Removes every active instance for the id.

- Returns `true, nil` when the instances are removed.
- Returns `false, "TagNotActive"` without events when no instance is active.

### `RemoveSingleTag(tagId: string) -> (boolean, string?)` {#remove-single-tag}

Removes exactly one instance: the oldest applied stack. The remaining instances stay active.

- Returns `true, nil` when one instance is removed.
- Returns `false, "TagNotActive"` without events when no instance is active.

### `HasTag(tagId: string) -> boolean` {#has-tag}

Returns whether at least one instance is active.

### `GetActiveTags() -> {ActiveTagSnapshot}` {#get-active-tags}

Returns one aggregate snapshot per active tag id, ordered by the oldest active application across tags.

### `GetTagInstances(tagId: string) -> {TagInstanceSnapshot}` {#get-tag-instances}

Returns per-instance snapshots in stored stack order, or an empty array when inactive.

### `Destroy() -> ()` {#destroy}

Stops advancement, clears active state, and destroys owned events. Repeated calls are no-ops. Normal gameplay code should let Actor teardown call this method.

## Events

All events use payload `(actor: Actor, tagId: string)`.

### `OnTagAdded: Event<Actor, string>` {#on-tag-added}

Fires when a new instance is stored.

### `OnTagRefreshed: Event<Actor, string>` {#on-tag-refreshed}

Fires when an existing instance resets.

### `OnTagRemoved: Event<Actor, string>` {#on-tag-removed}

Fires when one or all instances are removed manually.

### `OnTagExpired: Event<Actor, string>` {#on-tag-expired}

Fires when a timed instance expires.

### `OnTagChanged: Event<Actor, string>` {#on-tag-changed}

Fires when active tag state changes.

## Related

- [Tag Registry](./tag-registry)
- [Property Controller](../Property/property-controller)
- [Tag Runtime guide](/Tags/tag-runtime)
