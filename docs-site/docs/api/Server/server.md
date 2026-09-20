# Server

`Server` initializes KRF's controller, tag, and resource catalogs before Actors are registered.

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

Combines KRF's built-in controllers with `config.controllers`, then validates and publishes the controller, tag, and resource catalogs in one startup attempt.

- Returns `true, nil` when all catalogs load.
- Returns `false, { system, reason }` when validation or loading fails. The catalogs remain unpublished for validation failures.
- Returns a `Server` failure on a repeated attempt, including after a failed first attempt.

## Related

- [Initializing KRF](/initializing-krf)
- [Controller Registry](../Controllers/controller-registry)
