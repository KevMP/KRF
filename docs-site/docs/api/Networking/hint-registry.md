# HintRegistry

`HintRegistry` provides read access to the immutable Hint catalog published by `Server.Init`.

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Registry = require(ReplicatedStorage.Packages.KRF.server.Networking.HintRegistry)
```

## Members

| Kind | Signature |
| --- | --- |
| Method | [`IsLoaded() -> boolean`](#is-loaded) |
| Method | [`Get(hintId: string) -> LoadedHintDefinition?`](#get) |
| Method | [`GetAll() -> {LoadedHintDefinition}`](#get-all) |

### `IsLoaded() -> boolean` {#is-loaded}

Returns true after startup publishes the catalog, including an empty catalog.

### `Get(hintId: string) -> LoadedHintDefinition?` {#get}

Returns the immutable definition or nil. It contains the id, direction, target, mode, compiled payload schema and optional server callback references. The compiled schema representation is private.

### `GetAll() -> {LoadedHintDefinition}` {#get-all}

Returns the frozen array sorted by id. Before startup it is empty. Register through `Server.Init({ hints = ... })`; runtime mutation is unsupported.

## Related

- [Hint definitions](/Networking/hints)
- [Server](/api/Server/)
