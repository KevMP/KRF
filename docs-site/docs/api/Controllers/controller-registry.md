---
sidebar_position: 1
---

# Controller Registry

`ControllerRegistry` stores Actor controller factories and resolves dependency-safe attachment order. Register definitions during server startup, before registering Actors.

## Import

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF

local ControllerRegistry = require(KRF.server.Controller.ControllerRegistry)
```

## Members

| Kind | Signature |
| --- | --- |
| Method | [`Register(controllerDefinition: ControllerDef) -> (boolean, string?)`](#register) |
| Method | [`Get(key: string) -> ControllerDef?`](#get) |
| Method | [`GetKeys() -> {string}`](#get-keys) |
| Method | [`GetAutoAttachKeys() -> {string}`](#get-auto-attach-keys) |
| Method | [`ResolveOrder(keys: {string}) -> ({string}?, string?)`](#resolve-order) |

## Methods

### `Register(controllerDefinition: ControllerDef) -> (boolean, string?)` {#register}

Adds the definition under its key.

- Returns `true, nil` on success.
- Returns `false, "DuplicateControllerKey"` without replacing the existing definition when the key is occupied.

### `Get(key: string) -> ControllerDef?` {#get}

Returns the registered definition or `nil` for an unknown key.

### `GetKeys() -> {string}` {#get-keys}

Returns a new array of every key in registration order.

### `GetAutoAttachKeys() -> {string}` {#get-auto-attach-keys}

Returns a new array of keys whose definitions do not set `autoAttach = false`, preserving registration order.

### `ResolveOrder(keys: {string}) -> ({string}?, string?)` {#resolve-order}

Returns a dependency-safe order for the unique requested keys. When several keys are eligible, the earlier registered key wins.

| Failure reason | Meaning |
| --- | --- |
| `UnknownControllerKey:<key>` | A requested key is not registered. |
| `MissingDependency:<key>-><dependency>` | The definition names an unregistered dependency. |
| `DependencyNotInAttachSet:<key>-><dependency>` | The dependency exists but was not requested. |
| `CyclicDependency` | The requested dependency graph contains a cycle. |

Duplicate requested keys and duplicate dependency entries are ignored. An empty request returns an empty order.

## Related

- [Actor Runtime](../Actor/actor-runtime)
- [Actor](../Actor/)
- [Actor Runtime guide](/Actor/actor-runtime)
