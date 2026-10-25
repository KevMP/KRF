# HintAuthorization

These server helpers authorize ClientToServer Hint contexts while their callback is active.

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Authorization = require(ReplicatedStorage.Packages.KRF.server.Networking.HintAuthorization)
```

## Members

| Kind | Signature |
| --- | --- |
| Function | [`AnyReadyClient(context: HintContext, payload: any) -> (boolean, string?)`](#any-ready-client) |
| Function | [`OwnerActor(context: HintContext, payload: any) -> (boolean, string?)`](#owner-actor) |

### `AnyReadyClient(context: HintContext, payload: any) -> (boolean, string?)` {#any-ready-client}

Allows any currently Ready sender with a live framework-owned context. Otherwise returns false, `ClientNotReady`. The payload is ignored.

### `OwnerActor(context: HintContext, payload: any) -> (boolean, string?)` {#owner-actor}

Allows a Ready sender only when the resolved target Actor is currently associated with that Player in both directions. Otherwise returns false, `ActorNotOwned`. The payload is ignored. Merely being aware of the Actor is insufficient.

Both functions deny forged or expired contexts. Assign either as a definition's `authorize` callback, or compose it within a non-yielding custom policy.

## Related

- [Hints](/Networking/hints)
- [HintRegistry](./hint-registry)
