# ActorView

`ActorView` is the stable read-only client representation of one authoritative Actor.

```lua
local view = Registry.GetActorViewById(actorId) -- ActorViewRegistry
```

## Members

| Kind | Signature |
| --- | --- |
| Method | [`GetId() -> string`](#id) |
| Method | [`GetModel() -> Model?`](#model) |
| Method | [`GetDomain(domainId: string) -> DomainView?`](#domain) |
| Method | [`GetDomainIds() -> { string }`](#domains) |
| Event | [`OnModelChanged: Event<Model?, Model?>`](#model-changed) |

## Methods

### `GetId() -> string` {#id}

Returns the Actor's stable public runtime identity.

### `GetModel() -> Model?` {#model}

Returns the currently bound local Model, or `nil` when unavailable.

### `GetDomain(domainId: string) -> DomainView?` {#domain}

Returns the visible domain, or `nil` for an unknown, invisible or retired domain.

### `GetDomainIds() -> { string }` {#domains}

Returns an immutable snapshot of visible domain ids in ascending order.

## Events

### `OnModelChanged: Event<Model?, Model?>` {#model-changed}

Fires with `(previousModel, currentModel)` when the local binding changes.

## Related

- [ActorViews guide](/Networking/actor-views)
- [ActorView Registry](./actor-view-registry)
- [DomainView](./domain-view)
