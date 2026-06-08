---
sidebar_position: 1
---

# Actor Runtime

`ActorRuntime` is the public server-side entrypoint for registering and unregistering live KRF actors.

## Import

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF

local ActorRuntime = require(KRF.server.Actor.ActorRuntime)
```

## Methods

### `RegisterActor(model, opts?) -> (Actor?, string?)`

Registers a `Model` as a live actor.

Returns:

* `Actor` on success
* `nil, reason` on failure

Common failure reasons include duplicate model binding or controller attachment failure.

### `UnregisterActor(actor, reason?) -> (boolean, string?)`

Unregisters a live actor and tears down its controllers.

Returns:

* `true, nil` on success
* `false, reason` if the actor is already unregistered or teardown cannot proceed

### `AttachControllers(actor) -> (boolean, string?)`

Attaches every controller currently marked for automatic attachment in `ControllerRegistry`.

This is usually called by `RegisterActor`, not directly by game code.

### `DetachAllControllers(actor) -> ()`

Detaches and destroys every controller currently attached to the actor.

This is usually called by `UnregisterActor`, not directly by game code.

## Events

### `OnActorRegistered`

Fires after registration succeeds and the actor is live.

Signature:

```lua
SignalTypes.Event<Actor>
```

### `OnActorUnregistering`

Fires after the actor is marked not live but before teardown completes.

Signature:

```lua
SignalTypes.Event<Actor, string?>
```

### `OnActorUnregistered`

Fires after controller teardown and model unbinding complete.

Signature:

```lua
SignalTypes.Event<Actor, string?>
```

## Related

* [Actor](/api/Actor/)
* [Controller Registry](../Controllers/controller-registry)
* [Actor Runtime concepts](/Actor/actor-runtime)
