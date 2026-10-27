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
| Catalog contract | [`HintDefinition`](#hint-definition) |

### `HintDefinition` {#hint-definition}

Author definitions using `server.Networking.types.HintDefinition`. Register the array through `Server.Init({ hints = ... })`; do not call registry preparation/publication methods from game code. All [definition fields and callback signatures](/Networking/hints#definition-fields) are documented in the guide. The enum fields have no defaults; `payload` is required. Unknown fields, sparse/unbounded catalogs and duplicate ids reject startup.

`authorize(context: HintContext, payload: any) -> (boolean, string?)` and `receive(context: HintContext, payload: any) -> ()` are required for ClientToServer definitions. Context contains read-only `player: Player`, `actor: Actor?` and `hintId: string`; payload is schema-owned and immutable. Authorization must return true explicitly. A false return denies without acknowledgement; throwing/yielding authorizers deny, and receive faults are isolated. Reasons remain server-local, not command results. These callbacks are non-yielding and non-authoritative.

ServerToClient definitions may omit both callbacks; supplied values must still be functions. Clients observe the [HintRuntime receipt event](./hint-runtime#on-hint-received). Startup never invokes callbacks. Source definition/schema edits after successful startup do not change the frozen catalog.

Startup failure reports `system = "Hint"` and a validator reason such as `HintFieldUnknown`, `HintIdInvalid`, `DuplicateHintId`, `HintDirectionInvalid`, `HintTargetInvalid`, `HintModeInvalid`, `HintAuthorizationRequired`, `HintReceiverRequired`, a schema error, or `HintRecordTooLarge`. The size check includes complete per-record framing. See [startup failure handling](/Networking/startup#handle-startup-failures).

### `IsLoaded() -> boolean` {#is-loaded}

Returns true after startup publishes the catalog, including an empty catalog.

### `Get(hintId: string) -> LoadedHintDefinition?` {#get}

Returns the immutable definition or nil. It contains the id, direction, target, mode, compiled payload schema and optional server callback references. The compiled schema representation is private.

### `GetAll() -> {LoadedHintDefinition}` {#get-all}

Returns the frozen array sorted by id. Before startup it is empty. Register through `Server.Init({ hints = ... })`; runtime mutation is unsupported.

## Related

- [Hint definitions](/Networking/hints)
- [Server](/api/Server/)
