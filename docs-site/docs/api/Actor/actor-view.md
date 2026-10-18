# ActorView

`ActorView` is the stable read-only client representation of one authoritative Actor.

```lua
--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local Registry = require(KRF.client.Actor.ActorViewRegistry)
local ViewTypes = require(KRF.client.Actor.types)

local model: Model? = Players.LocalPlayer.Character
local view: ViewTypes.ActorView? = if model ~= nil then Registry.GetActorViewByModel(model) else nil
if view == nil then
	return -- No complete view for this Model yet; observe the registry for later arrivals.
end
```

## Members

| Kind | Signature |
| --- | --- |
| Method | [`GetId() -> string`](#id) |
| Method | [`GetModel() -> Model?`](#model) |
| Method | [`GetTags() -> TagsView`](#tags) |
| Method | [`GetDomain(domainId: string) -> DomainView?`](#domain) |
| Method | [`GetDomainIds() -> { string }`](#domains) |
| Method | [`IsAvailable() -> boolean`](#available) |
| Event | [`OnModelChanged: Event<Model?, Model?>`](#model-changed) |
| Event | [`OnDomainsChanged: Event<DomainMembershipChange>`](#domains-changed) |
| Event | [`OnUnavailable: Event<>`](#unavailable) |

## Methods

### `GetId() -> string` {#id}

Returns the Actor's stable public runtime identity.

### `GetModel() -> Model?` {#model}

Returns the currently bound local Model, or `nil` when unavailable.

### `GetDomain(domainId: string) -> DomainView?` {#domain}

Returns the visible domain, or `nil` for an unknown, invisible or retired domain.

### `GetTags() -> TagsView` {#tags}

Returns this ActorView's stable read-only [TagsView](./tags-view), including an empty view when no visible Tags domain exists.

### `GetDomainIds() -> { string }` {#domains}

Returns an immutable snapshot of visible domain ids in ascending order.

### `IsAvailable() -> boolean` {#available}

Returns whether the view retains valid domain truth; remains true during recovery and becomes false on terminal failure or removal.

## Events

### `OnModelChanged: Event<Model?, Model?>` {#model-changed}

Fires with `(previousModel, currentModel)` when the local binding changes.

### `OnDomainsChanged: Event<DomainMembershipChange>` {#domains-changed}

Fires when replacement or terminal failure changes the visible domain set.

### `OnUnavailable: Event<>` {#unavailable}

Fires once when terminal failure invalidates this view's domain truth.

## Related

- [ActorViews guide](/Networking/actor-views)
- [ActorView Registry](./actor-view-registry)
- [DomainView](./domain-view)
- [TagsView](./tags-view)
