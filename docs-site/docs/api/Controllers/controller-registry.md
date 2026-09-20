---
sidebar_position: 1
---

# Controller Registry

`ControllerRegistry` loads one immutable catalog of Actor controller factories and resolves dependency-safe attachment order.

For full KRF startup, pass game controller definitions to [`Server.Init`](/initializing-krf).

## Import

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF

local ControllerRegistry = require(KRF.server.Controller.ControllerRegistry)
```

## Members

| Kind | Signature |
| --- | --- |
| Method | [`Load(definitions: {ControllerDef}) -> (boolean, string?)`](#load) |
| Method | [`IsLoaded() -> boolean`](#is-loaded) |
| Method | [`Get(key: string) -> ControllerDef?`](#get) |
| Method | [`GetKeys() -> {string}`](#get-keys) |
| Method | [`GetAutoAttachKeys() -> {string}`](#get-auto-attach-keys) |
| Method | [`ResolveOrder(keys: {string}) -> ({string}?, string?)`](#resolve-order) |

## Methods

### `Load(definitions: {ControllerDef}) -> (boolean, string?)` {#load}

Validates and publishes the complete catalog once.

- Returns `true, nil` on success.
- Returns `false, reason` for an invalid definition, duplicate key, missing dependency, or dependency cycle. No definitions are published, and a corrected load may be attempted.
- Returns `false, "ControllerDefinitionsAlreadyLoaded"` after a successful load without changing the catalog.

### `IsLoaded() -> boolean` {#is-loaded}

Returns whether the registry has completed a successful load.

### `Get(key: string) -> ControllerDef?` {#get}

Returns the immutable loaded definition or `nil` for an unknown key.

### `GetKeys() -> {string}` {#get-keys}

Returns a new array of every key in catalog order.

### `GetAutoAttachKeys() -> {string}` {#get-auto-attach-keys}

Returns a new array of keys whose definitions do not set `autoAttach = false`, preserving catalog order.

### `ResolveOrder(keys: {string}) -> ({string}?, string?)` {#resolve-order}

Returns a dependency-safe order for the unique requested keys. When several keys are eligible, the earlier catalog key wins.

| Failure reason | Meaning |
| --- | --- |
| `UnknownControllerKey:<key>` | A requested key is not registered. |
| `DependencyNotInAttachSet:<key>-><dependency>` | The dependency exists but was not requested. |

Duplicate requested keys and duplicate dependency entries are ignored. An empty request returns an empty order.

## Related

- [Initializing KRF](/initializing-krf)
- [Actor Runtime](../Actor/actor-runtime)
- [Actor](../Actor/)
- [Actor Runtime guide](/Actor/actor-runtime)
