---
sidebar_position: 1
---

# Actor Runtime

`ActorRuntime` registers and unregisters server-side Actors. It is the supported lifecycle entrypoint for gameplay code.

## Import

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF

local ActorRuntime = require(KRF.server.Actor.ActorRuntime)
```

## Members

| Kind | Signature |
| --- | --- |
| Method | [`RegisterActor(model: Model, opts: RegisterActorOpts?) -> (Actor?, string?)`](#register-actor) |
| Method | [`UnregisterActor(actor: Actor, reason: string?) -> (boolean, string?)`](#unregister-actor) |
| Method | [`AttachControllers(actor: Actor) -> (boolean, string?)`](#attach-controllers) |
| Method | [`DetachAllControllers(actor: Actor) -> ()`](#detach-all-controllers) |
| Event | [`OnActorRegistered: Event<Actor>`](#on-actor-registered) |
| Event | [`OnActorUnregistering: Event<Actor, string?>`](#on-actor-unregistering) |
| Event | [`OnActorUnregistered: Event<Actor, string?>`](#on-actor-unregistered) |

## Methods

### `RegisterActor(model: Model, opts: RegisterActorOpts?) -> (Actor?, string?)` {#register-actor}

Creates an Actor for `model`, binds it, attaches every auto-attach controller, then sets `actor.enabled` to `true`.

**Returns**

- `actor, nil`: registration completed and `OnActorRegistered` fired.
- `nil, "ModelAlreadyRegistered"`: the model already belongs to another Actor.
- `nil, reason`: binding, controller ordering, factory, or attachment failed.

Registration is atomic from the caller's perspective. A controller failure destroys controllers attached during the attempt and clears the model binding before returning.

### `UnregisterActor(actor: Actor, reason: string?) -> (boolean, string?)` {#unregister-actor}

Disables a live Actor, fires the teardown events, destroys all controllers, and clears model and registry bindings.

**Returns**

- `true, nil`: teardown completed.
- `false, "AlreadyUnregistered"`: `actor.enabled` was already `false`; no teardown event fired.

A bound model being destroyed or parented to `nil` invokes this method with reason `"ModelGone"`.

### `AttachControllers(actor: Actor) -> (boolean, string?)` {#attach-controllers}

Resolves all auto-attach controller definitions through `ControllerRegistry`, creates them in dependency order, and attaches them to `actor`.

Failure rolls back only the controllers attached by that call, in reverse attach order. Existing controllers remain attached. Reasons identify ordering, factory, contract, or occupied-key failures.

### `DetachAllControllers(actor: Actor) -> ()` {#detach-all-controllers}

Removes every attached controller and calls its `Destroy()` method. A controller error is warned and does not prevent later controllers from being removed.

## Events

### `OnActorRegistered: Event<Actor>` {#on-actor-registered}

Fires when Actor registration succeeds.

### `OnActorUnregistering: Event<Actor, string?>` {#on-actor-unregistering}

Fires when Actor unregistration begins.

### `OnActorUnregistered: Event<Actor, string?>` {#on-actor-unregistered}

Fires when Actor unregistration completes.

## Related

- [Actor](./)
- [Actor Registry](./actor-registry)
- [Controller Registry](../Controllers/controller-registry)
- [Actor Runtime guide](/Actor/actor-runtime)
