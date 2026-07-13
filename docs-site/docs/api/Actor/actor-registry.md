---
sidebar_position: 3
---

# Actor Registry

`ActorRegistry` is the server-side lookup and model-binding store for live Actors.

:::info Infrastructure API
Use `ActorRuntime` to create and destroy Actors. Use this registry when a server system only needs lookup by model or runtime id.
:::

## Import

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF

local ActorRegistry = require(KRF.server.Actor.ActorRegistry)
```

## Members

| Kind | Signature |
| --- | --- |
| Method | [`GetActorById(actorId: string) -> Actor?`](#get-actor-by-id) |
| Method | [`GetActorByModel(actorModel: Model) -> Actor?`](#get-actor-by-model) |
| Method | [`BindModel(actor: Actor, model: Model) -> (boolean, string?)`](#bind-model) |
| Method | [`UnbindModel(actor: Actor) -> boolean`](#unbind-model) |

## Methods

### `GetActorById(actorId: string) -> Actor?` {#get-actor-by-id}

Returns the currently bound Actor with that runtime id, or `nil` after unbinding.

### `GetActorByModel(actorModel: Model) -> Actor?` {#get-actor-by-model}

Returns the Actor currently bound to `actorModel`, or `nil` when the model is unbound.

### `BindModel(actor: Actor, model: Model) -> (boolean, string?)` {#bind-model}

Creates id and model lookups, assigns `actor.model`, and begins watching the model for destruction or `Parent = nil`.

**Returns**

- `true, nil`: binding and cleanup tracking started.
- `false, "ModelAlreadyRegistered"`: the model is already bound; no binding changed.
- `false, "ActorHasDifferentModelBinded"`: the Actor already points at another model; no binding changed.

`ActorRuntime.RegisterActor(...)` performs this operation before attaching controllers.

### `UnbindModel(actor: Actor) -> boolean` {#unbind-model}

Clears id and model lookups, disconnects model tracking, and sets `actor.model` to `nil`. Returns `false` when the Actor has no registry record.

## Related

- [Actor Runtime](./actor-runtime)
- [Actor](./)
- [Actor Runtime guide](/Actor/actor-runtime)
