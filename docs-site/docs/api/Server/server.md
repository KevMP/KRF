# Server

`Server` initializes KRF's registries and networking transport before Actors are registered.

## Import

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Server = require(ReplicatedStorage.Packages.KRF.server)
```

## Members

| Kind | Signature |
| --- | --- |
| Method | [`Init(config: ServerStartConfig) -> (boolean, StartupFailure?)`](#init) |

## Methods

### `Init(config: ServerStartConfig) -> (boolean, StartupFailure?)` {#init}

Combines built-in and game definitions, then prepares and publishes the registries and networking transport in one non-yielding startup attempt.

- Returns `true, nil` when all registries and the transport are ready.
- Returns `false, { system, reason }` when preparation or publication fails; partially published startup state is rolled back.
- Networking failures use `system = "Networking"`, including `TransportConflict`, `BootstrapManifestTooLarge`, `InvalidProtocolManifest`, and `CodecCompilationFailure`.
- Command catalog failures use `system = "Command"`. Supply `config.commands` as an array of [command definitions](/Networking/commands); omission means an empty catalog. Authorization and handlers are required even for commands without schemas.
- Action request failures use `system = "ActionRequest"`. Supply `config.actionRequestSchemas` as the shared [Action request](/Action/action-requests) module; an id missing from the Action catalog fails with `ActionRequestUnknownAction`, and a non-function `config.actionControlAuthority` with `ActionControlAuthorityInvalid`.
- The command ids `KRF.Action.Start`, `KRF.Action.Stop` and `KRF.Action.Interrupt` are reserved. A consumer command using one fails with `system = "Command"`, `CommandIdReserved`, whether or not request schemas are supplied.
- Hint catalog failures use `system = "Hint"`. Supply `config.hints` as an array of [Hint definitions](/Networking/hints); omission means an empty catalog. ClientToServer Hint callbacks receive validated presentation samples after explicit authorization. ServerToClient samples use explicit `HintRuntime.SendTo` recipients.
- Returns a `Server` failure with `ServerInitAlreadyAttempted` on a repeated attempt, including after a failed first attempt, or `CatalogAlreadyLoaded` when a registry was loaded before startup.

## Related

- [Initializing KRF](/initializing-krf)
- [Networking startup](/Networking/startup)
- [Controller Registry](../Controllers/controller-registry)
- [Action Registry](../Action/action-registry)
- [Action Controller](../Action/action-controller)
- [Action requests](/Action/action-requests)
- [Replication Domain Registry](../Networking/replication-domain-registry)
