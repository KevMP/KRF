# Actor Runtime

`ActorRuntime` is the main server side lifecycle entrypoint for gameplay actors in KRF.

If a `Model` should participate in gameplay through KRF, register it through `ActorRuntime`. When it should stop participating, tear it down through `ActorRuntime`.

## What an Actor is

An Actor is KRF's server authoritative representation of a gameplay participant.

Common examples include:

* a player character
* an NPC
* another world participant that needs framework managed state

Actors are usually bound to a Roblox `Model`, but an Actor is not defined by whether something is a `Character`. The important part is that KRF treats it as a tracked gameplay participant with a managed lifecycle.

## Core ideas

* Each Actor has an internal identity through `actor.id`.
* Registered actors are tracked by both `actor.id` and bound `Model`.
* `ActorRegistry` stores those bindings and clears them during teardown.
* `ActorRuntime` owns the supported registration and teardown flow.
* A model that is already registered cannot be rebound to a different actor at the same time.

## Registering an Actor

Use `ActorRuntime.RegisterActor(model, opts?)` when a `Model` should become a live framework actor.

Registration follows a fixed flow:

1. create the actor
2. bind it to the model
3. attach controllers
4. mark the actor live
5. fire `OnActorRegistered`

If registration fails during bind or controller attach, the runtime does not leave behind a half live actor.

If controller attach fails, the runtime detaches any controllers attached in that same call, unbinds the model, and returns failure.

### Example: player spawn

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ActorRuntime = require(ReplicatedStorage.Packages.KRF.server.Actor.ActorRuntime)
local ActorEntity = require(ReplicatedStorage.Packages.KRF.server.Actor.ActorEntity)

local function onCharacterAdded(character: Model): ()
	local actor: ActorEntity.Actor?, reason: string? = ActorRuntime.RegisterActor(character)

	if actor == nil then
		warn(("Failed to register actor: %s"):format(reason or "unknown"))
		return
	end
end
```

A respawn is a new actor lifecycle. A new character model goes through a new registration flow.

## Unregistering an Actor

Use `ActorRuntime.UnregisterActor(actor, reason?)` when a live actor should be removed from the framework.

Unregistration follows this flow:

1. mark the actor not live
2. fire `OnActorUnregistering`
3. detach and destroy all controllers
4. unbind the model
5. fire `OnActorUnregistered`

After unregistration:

* lookup by model is cleared
* lookup by actor id is cleared
* `actor.model` is cleared

Unregistration is idempotent. Calling it again returns failure with `AlreadyUnregistered` and does not recreate state.

### Example: explicit cleanup

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ActorRuntime = require(ReplicatedStorage.Packages.KRF.server.Actor.ActorRuntime)
local ActorEntity = require(ReplicatedStorage.Packages.KRF.server.Actor.ActorEntity)

local function cleanupActor(actor: ActorEntity.Actor): ()
	local ok: boolean, reason: string? = ActorRuntime.UnregisterActor(actor, "Despawn")

	if not ok then
		warn(("Failed to unregister actor: %s"):format(reason or "unknown"))
	end
end
```

## Automatic cleanup

If a bound model is destroyed, or removed from the DataModel with `Parent = nil`, KRF routes cleanup through `ActorRuntime.UnregisterActor(...)`.

This clears the actor's registration state even if the model disappears unexpectedly.

Explicit cleanup is still the clearest ownership model when a game already knows an actor is being despawned.

## Controller wiring

Controller wiring is driven by `ControllerRegistry`.

Each controller definition includes:

* a unique `key`
* a `factory(actor)` that creates the controller for that actor
* optional `dependsOn` entries for attach ordering
* optional `autoAttach`, which defaults to `true`

Controllers with `autoAttach ~= false` are part of the default actor registration flow.

Attach order is resolved from `dependsOn` before attachment starts. If more than one controller is eligible to attach at the same time, order is deterministic and follows controller registration order.

Invalid controller sets fail fast. That includes:

* unknown controller keys
* missing dependencies
* dependencies outside the requested attach set
* cyclic dependencies

Controller attachment is not partial. If attachment fails during a call to `AttachControllers`, KRF rolls back any controllers attached in that same call.

Controllers are destroyed during teardown. Each controller is expected to implement `Destroy()` so the runtime can clean it up consistently.
