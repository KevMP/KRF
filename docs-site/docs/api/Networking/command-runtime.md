# CommandRuntime

`CommandRuntime` sends validated requests and reports their correlated outcomes after client startup.

```lua
local Commands = require(ReplicatedStorage.Packages.KRF.client.Networking.CommandRuntime)
```

## Members

| Kind | Signature |
| --- | --- |
| Method | [`Send(commandId: string, actorView: ActorView?, request: any?) -> (number?, string?)`](#send) |
| Event | [`OnCommandResult: Event<CommandResult>`](#result) |
| Event | [`OnCommandUncertain: Event<CommandResult>`](#uncertain) |

## Methods

### `Send(commandId: string, actorView: ActorView?, request: any?) -> (number?, string?)` {#send}

Returns an increasing connection-local U32 request id on local admission, or `nil, reason` without transmitting. Call with dot syntax. Actor targets require the exact available view in the current ActorViewRegistry; None targets require `nil`.

| Reason | Condition |
| --- | --- |
| `ClientNotReady` | Startup has not reached READY, or the installed runtime was shut down |
| `UnknownCommand` | The startup catalog has no such id |
| `ActorViewUnavailable` | Actor target is missing, forged, stale, unavailable, or lacks the current private stream mapping |
| `UnexpectedActorTarget` | A None-target command received an ActorView |
| `RequestIdExhausted` | The next id cannot fit in U32; ids never wrap |
| `CommandPendingFull` | Pending metadata reached its count or byte limit |
| `UnexpectedCommandPayload` | A request was supplied without a request schema |

Schema validation errors also return locally. Successful admission is not server acceptance. A transport exception after admission reports uncertainty for that request id.

## Events

### `OnCommandResult: Event<CommandResult>` {#result}

Fires once for a correlated definitive Accepted or Rejected result, including a late result within the uncertainty grace window. For synchronous command effects, its callback begins before the requester's later Actor state/semantic callbacks.

### `OnCommandUncertain: Event<CommandResult>` {#uncertain}

Fires at most once per admitted request with `status = "Unknown"`. Framework reasons include `CommandTimeout`, `CommandTransportFault`, `CommandConnectionClosed`, `CommandAuthorizationFault`, `CommandHandlerFault`, and `CommandResultFault`. Unknown never means rejection, cancellation, or rollback. A definitive result may follow timeout uncertainty within the same connection's grace window.

Both events use KRF's read-only `Connect`, `Once`, and `Wait` surface. Their immutable payload has these fields:

| Field | Value |
| --- | --- |
| `requestId` | The id returned by Send |
| `commandId` | Catalog id |
| `targetActorView` | The originally admitted ActorView, when targeted; it may since have retired |
| `status` | `Accepted`, `Rejected`, or `Unknown` |
| `result` | Validated immutable result for Accepted, when a result schema exists |
| `reason` | Nonempty bounded reason for Rejected or Unknown |

The type is `client.Networking.types.CommandResult`. No raw buffers, private handles, or RemoteEvents are exposed.

## Related

- [Commands guide](/Networking/commands)
- [Client startup](/api/Client/)
- [ActorView](../Actor/actor-view)
