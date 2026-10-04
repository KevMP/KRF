# Server

`Server` initializes KRF's controller, Tag, Resource, and Action registries before Actors are registered.

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

Combines KRF's built-in controllers with `config.controllers`, then validates and publishes the controller, Tag, Resource, and Action registries in one startup attempt.

- Returns `true, nil` when all registries load.
- Returns `false, { system, reason }` when validation or loading fails. The registries remain unpublished for validation failures.
- Returns a `Server` failure on a repeated attempt, including after a failed first attempt.

## Related

- [Initializing KRF](/initializing-krf)
- [Controller Registry](../Controllers/controller-registry)
- [Action Registry](../Action/action-registry)
- [Action Controller](../Action/action-controller)
