---
sidebar_position: 1
---

# Controller Registry

`ControllerRegistry` stores controller definitions and resolves their attach order.

Use it when your game or framework code needs to register an actor controller that should participate in KRF actor startup.

## Import

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF

local ControllerRegistry = require(KRF.server.Controller.ControllerRegistry)
```

## Controller Definition Shape

```lua
type ControllerDef = {
	key: string,
	factory: (actor: Actor) -> Controller,
	dependsOn: { string }?,
	autoAttach: boolean?,
}
```

## Methods

### `Register(controllerDefinition) -> (boolean, string?)`

Registers a controller definition by key.

Returns:

* `true, nil` on success
* `false, "DuplicateControllerKey"` when the key is already registered

### `GetKeys() -> {string}`

Returns controller keys in registration order.

### `Get(key) -> ControllerDef?`

Returns one controller definition by key.

### `GetAutoAttachKeys() -> {string}`

Returns the subset of controller keys that participate in automatic actor registration.

Controllers default to auto-attach unless `autoAttach` is explicitly `false`.

### `ResolveOrder(keys) -> ({string}?, string?)`

Resolves dependency-safe attach order for a specific controller key set.

This fails when:

* a key is unknown
* a dependency is missing
* a dependency is not part of the requested attach set
* the dependency graph is cyclic

## Related

* [Actor Runtime](../Actor/actor-runtime)
* [Actor Runtime concepts](/Actor/actor-runtime)
