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
- Returns a `Server` failure with `ServerInitAlreadyAttempted` on a repeated attempt, including after a failed first attempt, or `CatalogAlreadyLoaded` when a registry was loaded before startup.

## Related

- [Initializing KRF](/initializing-krf)
- [Networking startup](/Networking/startup)
- [Controller Registry](../Controllers/controller-registry)
- [Action Registry](../Action/action-registry)
- [Action Controller](../Action/action-controller)
- [Replication Domain Registry](../Networking/replication-domain-registry)
