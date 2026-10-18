# TagsView

`TagsView` is the immutable client facade for one Actor's active visible Tags.

```lua
local tags = actorView:GetTags()
-- Public contracts: KRF.client.Actor.types.TagsView and ActiveTagSnapshot.
```

## Members

| Kind | Signature |
| --- | --- |
| Method | [`HasTag(tagId: string) -> boolean`](#has-tag) |
| Method | [`GetTag(tagId: string) -> ActiveTagSnapshot?`](#get-tag) |
| Method | [`GetActiveTags() -> { ActiveTagSnapshot }`](#active-tags) |
| Event | [`OnTagAdded: Event<string>`](#added) |
| Event | [`OnTagRefreshed: Event<string>`](#refreshed) |
| Event | [`OnTagRemoved: Event<string>`](#removed) |
| Event | [`OnTagExpired: Event<string>`](#expired) |
| Event | [`OnStateChanged: Event<DomainChangeSource>`](#state-changed) |

## Methods

### `HasTag(tagId: string) -> boolean` {#has-tag}

Returns whether the id is currently active in visible authoritative state; unknown, private, and inactive ids return `false`.

### `GetTag(tagId: string) -> ActiveTagSnapshot?` {#get-tag}

Returns a newly derived immutable snapshot with `tagId`, authoritative `stackCount`, and optional `remainingDuration` in seconds. Returns `nil` for an unknown, private, inactive, or retired entry.

### `GetActiveTags() -> { ActiveTagSnapshot }` {#active-tags}

Returns an immutable array of immutable aggregate snapshots, sorted by semantic `tagId`; empty or retired views return an empty array.

## Events

### `OnTagAdded: Event<string>` {#added}

Fires with `(tagId: string)` when an authoritative visible Tag instance is added.

### `OnTagRefreshed: Event<string>` {#refreshed}

Fires with `(tagId: string)` when an authoritative visible instance refreshes, including when aggregate state is unchanged.

### `OnTagRemoved: Event<string>` {#removed}

Fires with `(tagId: string)` for explicit/manual removal of visible instances.

### `OnTagExpired: Event<string>` {#expired}

Fires with `(tagId: string)` for authoritative timed expiry of a visible instance; it does not replace manual Removed events.

### `OnStateChanged: Event<DomainChangeSource>` {#state-changed}

Fires with `(source: "Commit" | "Baseline")` when visible aggregate truth changes through a live commit or replacement baseline. Initial binding emits no change event.

## Related

- [TagsView guide](/Tags/tag-views)
- [ActorView](./actor-view)
- [ActorView Registry](./actor-view-registry)
