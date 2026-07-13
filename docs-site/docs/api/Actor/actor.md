---
sidebar_position: 2
---

# Actor

`Actor` represents one server-side gameplay participant and provides access to its actor-scoped controllers. `ActorRuntime.RegisterActor(...)` returns the live instance.

## Members

| Kind | Signature |
| --- | --- |
| Property | [`actor.model: Model?`](#model) |
| Property | [`actor.enabled: boolean`](#enabled) |
| Method | [`actor:GetId() -> string`](#get-id) |
| Method | [`actor:GetController(key: string) -> Controller?`](#get-controller) |
| Method | [`actor:GetControllerKeys() -> {string}`](#get-controller-keys) |
| Method | [`actor:SetController(key: string, controller: Controller) -> boolean`](#set-controller) |
| Method | [`actor:RemoveController(key: string) -> Controller?`](#remove-controller) |

## Properties

### `actor.model: Model?` {#model}

The current bound model. `ActorRuntime` clears it after unregistration. Treat this field as read-only in game code.

### `actor.enabled: boolean` {#enabled}

Whether the Actor is live. New Actor objects start disabled; registration enables them and teardown disables them. Treat this field as read-only in game code.

## Methods

### `actor:GetId() -> string` {#get-id}

Returns the Actor's immutable runtime id. External fields named `id` do not change this value.

### `actor:GetController(key: string) -> Controller?` {#get-controller}

Returns the controller attached under `key`, or `nil` when the key is unoccupied.

### `actor:GetControllerKeys() -> {string}` {#get-controller-keys}

Returns a new array containing all occupied controller keys. The array can be changed by the caller without changing the Actor; key order is not a public guarantee.

### `actor:SetController(key: string, controller: Controller) -> boolean` {#set-controller}

Attaches `controller` only when `key` is unoccupied. Returns `false` and preserves the existing controller on collision.

Controllers managed by `ActorRuntime` must provide `Destroy()`.

### `actor:RemoveController(key: string) -> Controller?` {#remove-controller}

Removes and returns the controller under `key`. Returns `nil` when none is attached. This method does not call `Destroy()`.

## Related

- [Actor Runtime](./actor-runtime)
- [Property Controller](../Property/property-controller)
- [Resource Controller](../Resource/resource-controller)
- [Tag Controller](../Tags/tag-controller)
