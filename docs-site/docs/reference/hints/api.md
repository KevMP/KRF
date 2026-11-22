---
title: Hints API
sidebar_label: API
---

# Hints API

Register `{KRF.HintDefinition}` through `Server.Init({ hints = definitions })`. Runtime facades use dot syntax and become available through ordinary KRF startup.

## HintDefinition

| Field | Type / contract |
| --- | --- |
| `id` | Unique nonempty string |
| `direction` | Required `"ClientToServer"` or `"ServerToClient"` |
| `target` | Required `"None"` or `"Actor"` |
| `mode` | Required `"Pulse"` or `"Latest"` |
| `payload` | Required SchemaDefinition |
| `authorize` | `(ctx: HintContext, payload: any) -> (boolean, string?)`; required for ClientToServer |
| `receive` | `(ctx: HintContext, payload: any) -> ()`; required for ClientToServer |

There are no defaults for direction, target or mode. Catalogs must be dense arrays of at most 1,024 definitions. ServerToClient may omit callbacks; supplied callbacks must still be functions, but these callbacks are not invoked for ServerToClient delivery. Payload always has a schema, even when it describes an empty record or an optional value.

`HintContext` has read-only `player: Player`, optional resolved `actor: Actor` and `hintId: string`. Received payloads are schema-owned and immutable. Authorization permits the receiver only when its first return value is exactly true; any second return value is ignored. Other results, errors and yields deny without acknowledgement. KRF rechecks the connection and Actor mapping after authorization.

Both callbacks must complete without yielding. KRF closes a callback at its first suspension and isolates thrown errors. Receiver faults do not undo side effects already performed or request automatic redelivery. Hints provide no authoritative gameplay transaction or result.

## ClientHintRuntime

```lua
KRF.ClientHintRuntime.Send(hintId: string, actorView: ActorView?, payload: any?)
	-> (boolean, string?)
```

Admits a ClientToServer sample after readiness. Actor targets require the exact current available registry view; None targets require nil. Returns `true, nil` on local admission or `false, reason` otherwise. No request ID or result is allocated. If the catalog has no ClientToServer definitions, the client sender is absent and Send returns `ClientNotReady`.

`OnHintReceived: Event<KRF.HintReceived>` reports validated ServerToClient samples after readiness:

| Receipt field | Type / meaning |
| --- | --- |
| `hintId` | Definition ID |
| `actorView` | Current available ActorView for an Actor target; nil for a None target |
| `payload` | Immutable schema-owned value; can be nil when the schema permits it |

Missing, retired or unavailable Actor targets drop without waiting for state recovery. Receipts neither install recoverable state nor advance Actor revisions. Latest suppresses duplicates and older samples for each definition/live target; Pulse has no such sequence filter. Event subscriptions use the shared [Event interface](../getting-started/events).

## ServerHintRuntime

```lua
KRF.ServerHintRuntime.SendTo(player: Player, hintId: string, actor: Actor?, payload: any?)
	-> (boolean, string?)
```

Admits a ServerToClient sample for one ready recipient. An Actor target requires that recipient's current awareness mapping; None requires nil. Choose and send to each recipient explicitly. Returns `true, nil` on local admission or `false, reason` otherwise. If no ServerToClient definitions are registered, the server sender is absent and returns `NetworkingNotInitialized`.

Payload encoding/ownership finishes before either sender method returns; later caller mutation cannot change queued samples. Latest replaces an unsent sample for the same definition, target and recipient. Pulse queues separate occurrences. Neither mode guarantees delivery or order. Mapping changes, connection closure and transport faults can discard admitted work without acknowledgement or retry.

## HintAuthorization

| Signature | Result |
| --- | --- |
| `KRF.HintAuthorization.AnyReadyClient(ctx: HintContext, payload: any) -> (boolean, string?)` | True for ready requesters; otherwise `ClientNotReady` |
| `KRF.HintAuthorization.OwnerActor(ctx: HintContext, payload: any) -> (boolean, string?)` | True for exact current Character ownership; otherwise `ActorNotOwned` |

Helpers use framework-owned context identity and ignore the payload. The context binding is valid during authorization and receive; retaining or copying it does not preserve authorization afterward. Custom NPC or delegated permissions need a custom policy.

## Send failures

| Reason | Cause |
| --- | --- |
| `NetworkingNotInitialized` | Server Hint sender unavailable, including a catalog without ServerToClient definitions |
| `ClientNotReady` | Client sender unavailable, or the client lifetime/recipient is not ready |
| `UnknownHint`, `HintDirectionMismatch` | Missing definition or wrong direction |
| `ActorViewUnavailable` | Invalid current client Actor target |
| `ActorUnavailable` | Server target lacks the recipient's current mapping |
| `UnexpectedActorTarget` | Actor supplied to a None-target Hint |
| `HintRateLimited`, `HintPendingFull`, `HintLatestKeysFull` | Rate, pending or distinct Latest-key budget exhausted |
| `HintSequenceExhausted` | Sequence counter cannot advance |

Schema value validation reasons and `HintRecordTooLarge` can also propagate. A ready sender counts attempts before definition and payload validation; encoded Latest replacements also consume the byte budget. Coalescing therefore does not bypass rate limits. Queue and Latest-key budgets remain bounded, and sequence history persists for live keys until Actor retirement or connection cleanup.

These are local refusal reasons. An admitted sample can still be dropped without an outcome event. No acknowledgements, automatic retries or historical replay are supplied. Client teardown disconnects Hint event subscriptions and discards pending send/receive work.

## HintRegistry

Server-side dot calls on `KRF.HintRegistry`:

| Signature | Result |
| --- | --- |
| `Get(hintId: string) -> LoadedHintDefinition?` | Frozen definition or nil |
| `GetAll() -> {LoadedHintDefinition}` | Frozen ID-sorted array; empty before publication |
| `IsLoaded() -> boolean` | True after publication, including an empty catalog |

Loaded entries contain direction, target, mode, compiled payload schema and optional server callback references. Definitions and schemas are copied during startup; later edits to the source catalog do not change the loaded contract. Schema metadata reaches clients; server callbacks remain server-local. Prepare/Publish and rollback belong to startup, not live game registration.

## Definition failures

Startup reports `system = "Hint"`:

| Reasons | Cause |
| --- | --- |
| `HintDefinitionsMustBeTable`, `HintDefinitionsMustBeBoundedArray`, `HintDefinitionMustBeTable` | Invalid catalog shape |
| `HintIdInvalid`, `DuplicateHintId` | Invalid or repeated ID |
| `HintFieldUnknown`, `HintDirectionInvalid`, `HintTargetInvalid`, `HintModeInvalid` | Unsupported field or enum value |
| `HintAuthorizationRequired`, `HintReceiverRequired` | ClientToServer callback missing or non-function |
| `HintRecordTooLarge` | Complete conservative record size exceeds the 900-byte packet ceiling |

[Schema failures](../schemas/api#failures) also apply. Definitions are frozen after successful startup; caller edits do not change the loaded contract.
