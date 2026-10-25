# HintRuntime

The client HintRuntime admits disposable presentation samples for ClientToServer definitions.

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Hints = require(ReplicatedStorage.Packages.KRF.client.Networking.HintRuntime)
```

## Members

| Kind | Signature |
| --- | --- |
| Method | [`Send(hintId: string, actorView: ActorView?, payload: any?) -> (boolean, string?)`](#send) |

### `Send(hintId: string, actorView: ActorView?, payload: any?) -> (boolean, string?)` {#send}

Admits a locally schema-validated sample after READY. Actor targets require a current, available ActorView; None targets require nil. True reports local admission, with no guarantee of delivery or server authorization. Latest replaces its unsent sample; Pulse occurrences may be dropped under pressure.

False returns a reason: `ClientNotReady`, `UnknownHint`, `HintDirectionMismatch`, `ActorViewUnavailable`, `UnexpectedActorTarget`, `HintRateLimited`, `HintPendingFull`, `HintLatestKeysFull`, `HintSequenceExhausted`, or a payload codec validation reason. No request id or result event is allocated. Payload data is encoded and owned at admission, so subsequent caller mutation cannot change the queued sample.

## Related

- [Hints](/Networking/hints)
- [HintAuthorization](./hint-authorization)
