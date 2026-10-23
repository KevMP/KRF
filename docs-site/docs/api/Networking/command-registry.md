# CommandRegistry

`CommandRegistry` provides read access to the immutable command catalog owned by `Server.Init`.

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Registry = require(ReplicatedStorage.Packages.KRF.server.Networking.CommandRegistry)
```

## Members

| Kind | Signature |
| --- | --- |
| Method | [`IsLoaded() -> boolean`](#is-loaded) |
| Method | [`Get(commandId: string) -> LoadedCommandDefinition?`](#get) |
| Method | [`GetAll() -> {LoadedCommandDefinition}`](#get-all) |

### `IsLoaded() -> boolean` {#is-loaded}

Returns true after startup publishes the catalog, including an explicitly empty catalog.

### `Get(commandId: string) -> LoadedCommandDefinition?` {#get}

Returns the immutable loaded definition or nil. Definitions contain the id, target mode, compiled optional request/result schemas, and server callback references. The compiled schema representation is private.

### `GetAll() -> {LoadedCommandDefinition}` {#get-all}

Returns the frozen array sorted by command id. Before startup it is empty. Register definitions through startup rather than mutating this catalog at runtime.

## Related

- [Commands guide](/Networking/commands)
- [Server](/api/Server/)
