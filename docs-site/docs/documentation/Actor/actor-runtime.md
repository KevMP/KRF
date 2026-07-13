# Actor Runtime

An Actor is KRF's server-side identity for one gameplay participant. `ActorRuntime` owns the supported transition between an untracked Roblox `Model` and a live Actor with attached controllers.

## Actor, model, and controller

| Object | Role | Lifetime owner |
| --- | --- | --- |
| `Model` | Roblox world representation | Your game |
| Actor | Stable runtime id, model binding, live state, controller access | `ActorRuntime` |
| Controller | Actor-scoped state such as tags, properties, or resources | Actor lifecycle |

An Actor is not limited to player characters. NPCs and other modeled gameplay participants can use the same lifecycle.

## Registration

`ActorRuntime.RegisterActor(model)` performs one transaction:

1. Create a disabled Actor.
2. Bind the Actor and model in `ActorRegistry`.
3. Resolve and attach all registered auto-attach controllers in dependency order.
4. Set `actor.enabled = true`.
5. Fire `OnActorRegistered`.

If binding or controller attachment fails, the call returns no Actor. Controllers created by the failed attempt are destroyed and the model binding is cleared.

```lua
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ActorRuntime = require(ReplicatedStorage.Packages.KRF.server.Actor.ActorRuntime)

local function registerCharacter(character: Model): ()
	local actor, reason = ActorRuntime.RegisterActor(character)
	if actor == nil then
		warn(("Actor registration failed: %s"):format(reason or "Unknown"))
		return
	end
end
```

A respawned character is a new model and a new Actor lifecycle.

## Teardown

`ActorRuntime.UnregisterActor(actor, reason?)` has a stable order:

1. Set `actor.enabled = false`.
2. Fire `OnActorUnregistering`.
3. Remove and destroy every controller.
4. Clear model and registry bindings.
5. Fire `OnActorUnregistered`.

Calling it again returns `AlreadyUnregistered` without repeating teardown.

Destroying the bound model or setting its parent to `nil` routes through the same teardown with reason `ModelGone`. Explicit unregistration is still preferable when your game already owns the despawn.

## Design rules

- Create and destroy gameplay Actors through `ActorRuntime`, not `ActorRegistry`.
- Treat `actor.model` and `actor.enabled` as runtime-owned fields.
- Put Actor-scoped gameplay state in controllers, not arbitrary tables beside the Actor.

## API reference

- [`ActorRuntime`](/api/Actor/actor-runtime)
- [`Actor`](/api/Actor/)
- [`ActorRegistry`](/api/Actor/actor-registry)
