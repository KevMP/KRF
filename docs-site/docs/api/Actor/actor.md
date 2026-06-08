---
sidebar_position: 2
---

# Actor

`Actor` is KRF's runtime object for one gameplay participant.

Games usually receive an actor from `ActorRuntime.RegisterActor(...)` and then interact with that actor through attached controllers.

## Core fields

### `actor.model: Model?`

The currently bound model for the actor. This becomes `nil` after unregistration.

### `actor.enabled: boolean`

Whether the actor is currently live in the runtime.

## Methods

### `actor:GetId() -> string`

Returns the actor's stable runtime id.

### `actor:GetController(key) -> Controller?`

Returns the controller attached at `key`, or `nil` if no controller is attached there.

### `actor:GetControllerKeys() -> {string}`

Returns every currently attached controller key.

### `actor:SetController(key, controller) -> boolean`

Attaches a controller to the actor if that key is not already occupied.

Returns `false` if a controller with that key is already attached.

### `actor:RemoveController(key) -> Controller?`

Removes and returns the controller attached at `key`, if one exists.

## Notes

`Actor` does not own gameplay rules by itself. In normal game code, it mostly acts as the access point for attached controllers such as `PropertyController` and `TagController`.

## Related

* [Actor Runtime](./actor-runtime)
* [Property Controller](../Property/property-controller)
* [Tag Controller](../Tags/tag-controller)
