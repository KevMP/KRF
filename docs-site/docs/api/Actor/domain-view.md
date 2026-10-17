# DomainView

`DomainView` exposes one visible domain's immutable current state and declared events.

```lua
local domain = view:GetDomain("Game.Stamina") -- ActorView
```

## Members

| Kind | Signature |
| --- | --- |
| Method | [`GetId() -> string`](#id) |
| Method | [`GetState() -> any`](#state) |
| Method | [`GetEvent(eventId: string) -> Event<any>?`](#event) |
| Event | [`OnChanged: Event<DomainChange>`](#changed) |

## Methods

### `GetId() -> string` {#id}

Returns the stable domain id.

### `GetState() -> any` {#state}

Returns complete recursively immutable state matching the domain schema, or `nil` after retirement.

### `GetEvent(eventId: string) -> Event<any>?` {#event}

Returns the stable read-only event surface for a declared event, or `nil` when undeclared or retired; that event fires with its schema-defined payload when the server publishes the occurrence.

## Events

### `OnChanged: Event<DomainChange>` {#changed}

Fires with complete previous/current snapshots and a `Commit` or `Baseline` source when retained domain truth changes.

## Related

- [ActorViews guide](/Networking/actor-views)
- [ActorView](./actor-view)
- [Replication domains](/Networking/replication-domains)
