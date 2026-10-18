# DomainView

`DomainView` exposes one visible domain's immutable current state and declared events.

```lua
--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local Registry = require(KRF.client.Actor.ActorViewRegistry)
local ViewTypes = require(KRF.client.Actor.types)

local model: Model? = Players.LocalPlayer.Character
local view: ViewTypes.ActorView? = if model ~= nil then Registry.GetActorViewByModel(model) else nil
local domain: ViewTypes.DomainView? = if view ~= nil then view:GetDomain("Game.Titles") else nil
if domain == nil then
	return -- The view or this game's domain is not currently available.
end
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

Returns complete recursively immutable state matching the domain schema; `nil` is valid for an Optional schema and is also returned after retirement, so it does not establish whether the domain is still current.

### `GetEvent(eventId: string) -> Event<any>?` {#event}

Returns the stable read-only event surface for a declared event, or `nil` when undeclared or retired; that event fires with its schema-defined payload when the server publishes the occurrence.

## Events

### `OnChanged: Event<DomainChange>` {#changed}

Fires with complete previous/current snapshots and a `Commit` or `Baseline` source when retained domain truth changes.

## Related

- [ActorViews guide](/Networking/actor-views)
- [ActorView](./actor-view)
- [Replication domains](/Networking/replication-domains)
