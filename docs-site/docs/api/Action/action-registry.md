---
sidebar_position: 1
---

# Action Registry

`ActionRegistry` provides read access to the static Action catalog published by `Server.Init`.

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ActionRegistry = require(ReplicatedStorage.Packages.KRF.server.Action.ActionRegistry)
```

## Members

| Kind | Signature |
| --- | --- |
| Method | [`Get(actionId: string) -> LoadedActionDefinition?`](#get) |
| Method | [`GetAll() -> {LoadedActionDefinition}`](#get-all) |
| Method | [`GetAllById() -> {[string]: LoadedActionDefinition}`](#get-all-by-id) |
| Method | [`IsLoaded() -> boolean`](#is-loaded) |

## Methods

### `Get(actionId: string) -> LoadedActionDefinition?` {#get}

Returns frozen normalized static metadata, or `nil` for an unknown id. Callback fields are not part of `LoadedActionDefinition`.

### `GetAll() -> {LoadedActionDefinition}` {#get-all}

Returns the frozen metadata array in declaration order.

### `GetAllById() -> {[string]: LoadedActionDefinition}` {#get-all-by-id}

Returns the frozen id-indexed catalog.

### `IsLoaded() -> boolean` {#is-loaded}

Returns whether the catalog has been published, including an empty catalog.

## Related

- [Action catalog guide](/Action/action-registry)
- [Server](/api/Server/)
