# CommandAuthorization

`CommandAuthorization` supplies explicit policies for command definitions registered at startup.

```lua
local Authorization = require(ReplicatedStorage.Packages.KRF.server.Networking.CommandAuthorization)
```

## Members

| Kind | Signature |
| --- | --- |
| Function | [`AnyReadyClient(context: CommandContext, request: any?) -> (boolean, string?)`](#any-ready-client) |
| Function | [`OwnerActor(context: CommandContext, request: any?) -> (boolean, string?)`](#owner-actor) |

### `AnyReadyClient(context: CommandContext, request: any?) -> (boolean, string?)` {#any-ready-client}

Allows a ready requester in the active command invocation. Otherwise returns `false, "ClientNotReady"`. It imposes no game-specific permission check.

### `OwnerActor(context: CommandContext, request: any?) -> (boolean, string?)` {#owner-actor}

Allows only the exact Player associated with the resolved Actor through Networking's current direct Character association. Otherwise returns `false, "ActorNotOwned"`. It uses the framework association, not a UserId or caller-authored context comparison. A None target or unassociated NPC fails this policy.

Assign these functions to `authorize`; the command runtime supplies the context. Custom policies receive `player`, optional resolved `actor`, `requestId`, `commandId`, and `context:GetPriorOutcome(requestId)`. Contexts are immutable and invocation-scoped. Callback rules and prior-outcome semantics are described in the guide.

## Related

- [Commands guide](/Networking/commands)
- [CommandRuntime](./command-runtime)
