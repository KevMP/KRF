# ActorView Registry

`ActorViewRegistry` provides read-only client lookup and lifecycle events for published ActorViews.

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Registry = require(ReplicatedStorage.Packages.KRF.client.Actor.ActorViewRegistry)
```

## Members

| Kind | Signature |
| --- | --- |
| Method | [`GetActorViewById(actorId: string) -> ActorView?`](#by-id) |
| Method | [`GetActorViewByModel(model: Model) -> ActorView?`](#by-model) |
| Method | [`GetAllActorViews() -> { ActorView }`](#all) |
| Event | [`OnActorViewAdded: Event<ActorView>`](#added) |
| Event | [`OnActorViewRemoving: Event<ActorView>`](#removing) |

## Methods

### `GetActorViewById(actorId: string) -> ActorView?` {#by-id}

Returns the published view for the public actorId, or `nil` when unavailable.

### `GetActorViewByModel(model: Model) -> ActorView?` {#by-model}

Returns the published view currently bound to the local Model, or `nil` when unbound.

### `GetAllActorViews() -> { ActorView }` {#all}

Returns an independent collection of currently published views.

## Events

### `OnActorViewAdded: Event<ActorView>` {#added}

Fires when an Actor's complete initial state becomes publicly available.

### `OnActorViewRemoving: Event<ActorView>` {#removing}

Fires when a published ActorView is being retired.

## Related

- [ActorViews guide](/Networking/actor-views)
- [ActorView](./actor-view)
- [DomainView](./domain-view)
