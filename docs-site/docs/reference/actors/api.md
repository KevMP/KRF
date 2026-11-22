---
title: Actors API
---

# Actors API

## ActorRuntime

### RegisterActor

```lua
KRF.ActorRuntime.RegisterActor(model: Model, options: KRF.RegisterActorOpts?) -> (KRF.Actor?, string?)
```

`model` is the character or NPC Model to bind. `options.properties` is an optional `{ [string]: number }` of registered Property IDs and finite initial base values. Returns the Actor and nil on success, or nil and a reason. Unknown option fields are rejected. Initial values are copied and installed before dependent Controller factories; they don't emit ordinary Property write events.

The Actor is enabled before `OnActorRegistered` fires. A lifecycle listener can unregister it before RegisterActor returns, so success is not a guarantee that it remains enabled after arbitrary listener code. Automatic Resource assignment failures can warn and leave a Resource absent without rejecting the Actor.

| Failure | Meaning |
| --- | --- |
| `ControllerDefinitionsNotLoaded` | Server startup has not succeeded |
| `ModelAlreadyRegistered` | Another Actor already owns the Model |
| `UnknownControllerKey:<key>` | An attachment definition cannot be found |
| `FactoryError:<key>` | A controller factory raised an error |
| `FactoryDidNotCreateController:<key>` | A factory returned no controller |
| `ControllerContractNotObliged:<key>` | The result has no `Destroy` function |
| `ControllerAttachmentFailed:<key>` | The key could not be installed |
| `InitialPropertyInstallationFailed` | Initial Property installation failed |
| `InvalidActorRegistrationOptions`, `InvalidActorProperties` | Invalid options table or Property map |
| `InvalidPropertyId`, `UnknownPropertyId`, `InvalidInitialPropertyValue` | Invalid Property override ID or non-finite value |
| `ActorModelMissing`, `ActorModelMarkerConflict` | Model was lost during construction or conflicts with reserved identity metadata |

Replication installation can return its own capture or subscription failure reason. A reported failure removes KRF's attempted binding, Controllers and publication state, and emits no successful registration event. KRF cannot undo arbitrary game side effects performed by a factory.

### UnregisterActor

```lua
KRF.ActorRuntime.UnregisterActor(actor: KRF.Actor, reason: string?) -> (boolean, string?)
```

Disables and tears down `actor`. The optional reason is passed to lifecycle events. Returns `true, nil`; an already disabled Actor returns `false, "AlreadyUnregistered"`. Automatic Model destruction or Parent removal supplies `"ModelGone"`.

Publication observers detach before Controllers are destroyed. Controller destruction has no dependency-order guarantee; a Destroy error is warned and cleanup continues for the other Controllers.

### Lifecycle events

| Event | Arguments | State when dispatched |
| --- | --- | --- |
| `OnActorRegistered` | `(actor: Actor)` | Bound, controllers attached, enabled |
| `OnActorUnregistering` | `(actor: Actor, reason: string?)` | Disabled; controllers still available |
| `OnActorUnregistered` | `(actor: Actor, reason: string?)` | Controllers detached and Model unbound |

All use the [Event interface](../getting-started/events). Keep teardown listeners prepared for state being removed during reentrant gameplay calls.

## Actor

| Member | Returns or effect |
| --- | --- |
| `actor:GetId() -> string` | Stable identity for this Actor's lifetime |
| `actor:GetController(key: string) -> Controller?` | Attached controller, or `nil` |
| `actor:GetControllerKeys() -> { string }` | Current keys; no ordering guarantee |
| `actor:SetController(key: string, controller: Controller) -> boolean` | Installs without replacing an existing key; `false` on collision |
| `actor:RemoveController(key: string) -> Controller?` | Removes and returns the object; does not call its `Destroy` method |
| `actor.model: Model?` | Bound Model, or `nil` after unbinding |
| `actor.enabled: boolean` | Framework-managed registration/advancement state |

Do not use direct attachment or `enabled` writes to bypass ActorRuntime's lifecycle. Prefer Controller definitions for automatic attachment.

## ActorRegistry

```lua
KRF.ActorRegistry.GetActorById(actorId: string) -> KRF.Actor?
KRF.ActorRegistry.GetActorByModel(model: Model) -> KRF.Actor?
```

Both return nil when no binding exists. During registration, Controller factories can find the bound Actor while it is still disabled. During `OnActorUnregistering`, it is also still indexed. Lookups report binding identity, not successful completion or current enablement.

## Lifecycle infrastructure

These exported methods support registration itself; normal game code uses RegisterActor and UnregisterActor.

| Signature | Contract |
| --- | --- |
| `ActorRuntime.AttachControllers(actor: Actor, options: RegisterActorOpts?) -> (boolean, string?)` | Attaches the automatic dependency set; reverses attachments made by this call on failure |
| `ActorRuntime.DetachAllControllers(actor: Actor) -> ()` | Removes and destroys controllers; no full Actor unregistration |
| `ActorRegistry.BindModel(actor: Actor, model: Model) -> (boolean, string?)` | Binds indexes and Model cleanup observers; rejects `ModelAlreadyRegistered` or `ActorHasDifferentModelBinded` |
| `ActorRegistry.UnbindModel(actor: Actor) -> boolean` | Removes the current binding; `false` when absent |
| `ActorRegistry.SetModelGoneHandler(handler: ((Actor, string) -> ())?) -> ()` | Installed by ActorRuntime; replacing it replaces automatic Model cleanup behavior |

See [Actors](./guide), [Controllers API](../controllers/api) and [ActorViews API](./client-views-api).
