---
sidebar_position: 3
---

# Actor Registry

`ActorRegistry` is KRF's runtime lookup table for actor bindings.

Most gameplay code should prefer `ActorRuntime`. Use `ActorRegistry` when another server system needs to find the current actor for a model or actor id.

## Import

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF

local ActorRegistry = require(KRF.server.Actor.ActorRegistry)
```

## Methods

### `GetActorById(actorId) -> Actor?`

Returns the currently registered actor for that runtime id.

### `GetActorByModel(actorModel) -> Actor?`

Returns the currently registered actor bound to that `Model`.

### `BindModel(actor, model) -> (boolean, string?)`

Binds an actor to a model and starts cleanup tracking for that model.

Returns:

* `true, nil` on success
* `false, "ModelAlreadyRegistered"` if that model is already bound
* `false, "ActorHasDifferentModelBinded"` if the actor is already bound to another model

`ActorRuntime.RegisterActor(...)` already does this as part of normal registration.

### `UnbindModel(actor) -> boolean`

Clears the actor's current model binding and lookup records.

Returns `false` if the actor is not currently registered.

## Notes

`ActorRegistry` is a low-level runtime utility. If you are creating or destroying actors, `ActorRuntime` is the supported higher-level entrypoint.

When a bound model is destroyed or removed from the DataModel, KRF still routes cleanup through normal actor teardown.

## Related

* [Actor Runtime](./actor-runtime)
* [Actor](/api/Actor/)
* [Actor Runtime concepts](/Actor/actor-runtime)
