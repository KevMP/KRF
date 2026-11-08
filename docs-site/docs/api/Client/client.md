# Client

`Client` initializes the local client's KRF networking protocol.

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Client = require(ReplicatedStorage.Packages.KRF.client)
```

## Members

| Kind | Signature |
| --- | --- |
| Method | [`Init(config: ClientInitConfig?) -> (boolean, StartupFailure?)`](#init) |

## Methods

### `Init(config: ClientInitConfig?) -> (boolean, StartupFailure?)` {#init}

Discovers the framework transport and completes protocol initialization; may yield. `config` is optional and accepts only `actionRequestSchemas`, the same [Action request](/Action/action-requests) module passed to `Server.Init`.

- Returns `true, nil` after the server acknowledges readiness.
- Returns `false, { system = "Client", reason = "ClientInitAlreadyAttempted" }` on any repeated attempt.
- Returns a `Client` failure before any network work with `ClientConfigInvalid` when `config` is not a table, or `ClientConfigFieldUnknown` for any other field.
- Action request failures use `system = "ActionRequest"`: a catalog reason when the module is invalid, `ActionRequestCommandsUnavailable` when the server published no request commands, or `ActionRequestCommandsIncompatible` when their contracts differ from this client's.
- Networking failures return `false, { system = "Networking", reason }` with one of the categories below.

| Reason | Meaning |
| --- | --- |
| `TransportUnavailable` | Framework transport was not discovered before the deadline |
| `InvalidTransport` | Discovered transport remained invalid through the deadline |
| `ProtocolMismatch` | Server and client protocol versions differ |
| `MalformedBootstrap` | Invalid protocol catalog or handshake data |
| `UnsupportedSchema` | Bootstrap contains an unsupported schema |
| `BootstrapTooLarge` | Bootstrap exceeds the framework packet budget |
| `ReadyRejected` | Readiness was rejected or its acknowledgement was invalid |
| `HandshakeTimeout` | Handshake did not complete before the deadline |

Unexpected startup errors use a reason beginning with `StartupInternalFailure:`; the diagnostic suffix is not a stable code.

## Related

- [Initializing KRF](/initializing-krf)
- [Networking startup](/Networking/startup)
- [ActorViews](/Networking/actor-views)
- [Action requests](/Action/action-requests)
- [Server API](/api/Server/)
