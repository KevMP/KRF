---
sidebar_position: 1
---

# Action Registry

`ActionRegistry` provides read access to static Action definitions published by `Server.Init`.

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

Returns frozen normalized static metadata, or `nil` for an unknown id. Callback fields are not included.

### `GetAll() -> {LoadedActionDefinition}` {#get-all}

Returns the frozen metadata array in declaration order.

### `GetAllById() -> {[string]: LoadedActionDefinition}` {#get-all-by-id}

Returns the frozen id-indexed registry.

### `IsLoaded() -> boolean` {#is-loaded}

Returns whether the registry has been published, including an empty registry.

Before publication, `Get` returns `nil` and collection reads return empty frozen tables.

## Related

- [Action types](./action-types)
- [Defining Actions / Action Registry](/Action/action-registry)
- [Server](/api/Server/)
