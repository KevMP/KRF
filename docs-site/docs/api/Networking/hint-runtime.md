# HintRuntime

HintRuntime sends disposable presentation samples in either direction and exposes validated server-originated receipts on the client.

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ClientHints = require(ReplicatedStorage.Packages.KRF.client.Networking.HintRuntime)
-- On the server:
local ServerHints = require(ReplicatedStorage.Packages.KRF.server.Networking.HintRuntime)
```

## Members

| Kind | Signature |
| --- | --- |
| Client method | [`Send(hintId: string, actorView: ActorView?, payload: any?) -> (boolean, string?)`](#send) |
| Server method | [`SendTo(player: Player, hintId: string, actor: Actor?, payload: any?) -> (boolean, string?)`](#send-to) |
| Client event | [`OnHintReceived: Event<HintReceived>`](#on-hint-received) |

### `Send(hintId: string, actorView: ActorView?, payload: any?) -> (boolean, string?)` {#send}

Admits a locally schema-validated sample after READY. Actor targets require a current, available ActorView; None targets require nil. True reports local admission, with no guarantee of delivery or server authorization. Latest replaces its unsent sample; Pulse occurrences may be dropped under pressure.

False returns a reason: `ClientNotReady`, `UnknownHint`, `HintDirectionMismatch`, `ActorViewUnavailable`, `UnexpectedActorTarget`, `HintRateLimited`, `HintPendingFull`, `HintLatestKeysFull`, `HintSequenceExhausted`, or a payload codec validation reason. No request id or result event is allocated. Payload data is encoded and owned at admission, so subsequent caller mutation cannot change the queued sample.

### `SendTo(player: Player, hintId: string, actor: Actor?, payload: any?) -> (boolean, string?)` {#send-to}

Admits a ServerToClient sample for one explicit Ready recipient. Actor targets require that recipient's current awareness mapping; None targets require nil. Payload encoding and ownership occur before admission returns. True reports local admission only. Mapping and availability changes can discard admitted samples before transport or receipt.

False returns `NetworkingNotInitialized` when the server Hint sender is unavailable; otherwise `ClientNotReady`, `UnknownHint`, `HintDirectionMismatch`, `ActorUnavailable`, `UnexpectedActorTarget`, `HintRateLimited`, `HintPendingFull`, `HintLatestKeysFull`, `HintSequenceExhausted`, or a payload codec validation reason. Repeat the call for each explicitly chosen recipient; aggregate bounds still apply. There is no automatic broadcast or client-hint relay.

### `OnHintReceived: Event<HintReceived>` {#on-hint-received}

Fires on the client for a validated ServerToClient record after READY. The frozen receipt contains `hintId`, optional `actorView` and immutable schema-owned `payload`. Actor targets resolve to current, available ActorViews. Unknown, retired or unavailable targets drop without waiting for baselines or triggering recovery.

Latest suppresses duplicate and older sequences independently per definition and live target. Receipts do not install recoverable state or change Actor revisions. Delivery, order and successful callbacks are not acknowledged. Listener errors and yields follow framework Signal isolation. Teardown disconnects listeners and drops pending receive work.

## Related

- [Hints](/Networking/hints)
- [HintAuthorization](./hint-authorization)
