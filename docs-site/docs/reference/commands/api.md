---
title: Commands API
sidebar_label: API
---

# Commands API

Register server definitions with `Server.Init({ commands = definitions })`. Client requests use `KRF.CommandRuntime` after client readiness.

## CommandDefinition

| Field | Type / contract |
| --- | --- |
| `id` | Unique nonempty string |
| `target` | `"None"` or `"Actor"`; required |
| `request` | Optional SchemaDefinition; absent accepts only nil |
| `result` | Optional SchemaDefinition for Accepted results; absent permits only nil |
| `authorize` | `(ctx: CommandContext, request: any) -> (boolean, string?)`; required, side-effect free, non-yielding |
| `handle` | `(ctx: CommandContext, request: any) -> CommandHandlerResult`; required, non-yielding |

Each request/result schema must have a conservative maximum of at most 16,384 encoded bytes. The combined catalog is limited to 1,024 Commands, including framework-owned Action Commands. IDs `KRF.Action.Start`, `KRF.Action.Stop` and `KRF.Action.Interrupt` are reserved. Unknown fields, duplicates and oversized/sparse catalogs reject startup. Startup copies definitions and schemas without invoking callbacks.

`authorize` must return `true, nil` to permit execution or `false, reason` to deny it, with a nonempty reason of at most 64 bytes. Non-boolean decisions, missing/invalid denial reasons, or a reason accompanying true produce `CommandAuthorizationFault`.

`CommandHandlerResult` permits only `accepted`, `result` and `reason`. Accepted results match the result schema and have no reason. Rejected outcomes carry no result and require a nonempty reason of at most 64 bytes. Invalid result-table shape produces `CommandHandlerFault`; invalid result values or status/payload combinations produce `CommandResultFault`.

Callback errors and yields are contained. KRF cancels a suspended callback and reports Unknown for authorization/handler/result faults rather than asserting that no effects occurred. It does not roll back game mutations.

### CommandContext

| Member | Meaning |
| --- | --- |
| `player: Player` | Current requester |
| `actor: Actor?` | Resolved current Actor for an Actor-targeted operation |
| `requestId: number`, `commandId: string` | Current operation identity |
| `ctx:GetPriorOutcome(requestId: number) -> CommandOutcome?` | Earlier retained completed outcome on this connection |

`CommandOutcome` is immutable and contains `requestId`, `commandId`, optional `targetActor`, `status`, `result` and optional `reason`. Lookup uses only this connection's history; current, future and evicted IDs return nil. History retains no original request payload and has bounded count, bytes and lifetime. After this invocation closes, retained contexts return nil from GetPriorOutcome and no longer satisfy authorization helpers.

## CommandAuthorization

Dot calls or definition callback references on `KRF.CommandAuthorization`:

| Signature | Result |
| --- | --- |
| `AnyReadyClient(ctx: CommandContext, request: any) -> (boolean, string?)` | True for a ready requester; otherwise `ClientNotReady` |
| `OwnerActor(ctx: CommandContext, request: any) -> (boolean, string?)` | True for the Player's exact current Character Actor; otherwise `ActorNotOwned` |

These helpers ignore the payload and use framework-owned context identity. They do not authorize arbitrary NPC control by UserId or local Actor selection.

## CommandRuntime

```lua
KRF.CommandRuntime.Send(commandId: string, actorView: ActorView?, request: any?)
	-> (number?, string?)
```

Returns a monotonically increasing connection-local U32 request ID on local admission, or nil/reason without admission. Actor targets require a current available registry ActorView and live stream mapping; a local Model is not required. None targets require nil. IDs never wrap. Payload encoding finishes before admission returns, so caller mutation cannot alter the queued request.

A transport fault after admission can produce Unknown for that ID before Send returns. No per-request object or automatic retry is supplied.

| Local refusal | Cause |
| --- | --- |
| `ClientNotReady` | Client has not reached readiness or its lifetime ended |
| `UnknownCommand` | No catalog entry |
| `ActorViewUnavailable` | Missing, forged, stale or unavailable Actor target |
| `UnexpectedActorTarget` | Actor supplied to a None target |
| `RequestIdExhausted` | Next ID would exceed U32 |
| `CommandPendingFull` | Pending count or byte budget exhausted |
| `UnexpectedCommandPayload` | Payload supplied without a request schema |
| `CommandPayloadTooLarge` | Encoded payload exceeds its byte budget |

Schema value failures also return locally. Server authorization, target validation and game rules can later reject an admitted request. Server rate or queue pressure can instead refuse ingress without a result, eventually producing a client timeout. Local admission does not reserve server execution.

### Result events

| Event | Delivery |
| --- | --- |
| `OnCommandResult: Event<CommandResult>` | At most one definitive Accepted or Rejected outcome for a correlated request, including a retained late final result |
| `OnCommandUncertain: Event<CommandResult>` | At most one Unknown outcome for an admitted request |

| `CommandResult` field | Type / meaning |
| --- | --- |
| `requestId`, `commandId` | Original admitted request |
| `targetActorView` | Optional exact original ActorView; may since have retired |
| `status` | `"Accepted"`, `"Rejected"` or `"Unknown"` |
| `result` | Immutable schema-owned result for Accepted, where declared |
| `reason` | Bounded nonempty reason for Rejected/Unknown |

Unknown reasons include `CommandTimeout`, `CommandTransportFault`, `CommandTransportYielded`, `CommandConnectionClosed`, `CommandAuthorizationFault`, `CommandHandlerFault` and `CommandResultFault`. Unknown does not establish rejection or rollback; a definitive result may follow in the grace window. Uncorrelated, mismatched and expired results are ignored.

For synchronous handler effects, the requester's result callback begins before the resulting Actor state/semantic callbacks. Older queued publications and baselines retain their earlier place; listener completion and later scheduled gameplay work are outside this guarantee. Session teardown reports unresolved requests as Unknown and disconnects runtime listeners. See [ordering and reconciliation](./guide).

## CommandRegistry

Server-side dot calls on `KRF.CommandRegistry`:

| Signature | Result |
| --- | --- |
| `Get(commandId: string) -> LoadedCommandDefinition?` | Frozen definition or nil |
| `GetAll() -> {LoadedCommandDefinition}` | Frozen ID-sorted array; empty before startup publication |
| `IsLoaded() -> boolean` | True after publication, including an empty catalog |

Loaded entries contain normalized metadata, compiled optional schemas and server callback references. Internal follow-up reservation metadata is framework-owned. Prepare/Publish and rollback methods belong to startup, not runtime game registration.

## Definition failures

Startup reports `system = "Command"` with reasons including:

| Reasons | Cause |
| --- | --- |
| `CommandDefinitionsMustBeTable`, `CommandDefinitionsMustBeBoundedArray`, `CommandDefinitionMustBeTable` | Invalid catalog shape |
| `CommandIdInvalid`, `DuplicateCommandId`, `CommandIdReserved` | Invalid, repeated or reserved ID |
| `CommandFieldUnknown`, `CommandTargetInvalid` | Unsupported field or target |
| `CommandAuthorizationRequired`, `CommandHandlerRequired` | Missing or non-function callback |
| `CommandPayloadTooLarge` | Schema's conservative payload maximum exceeds budget |

[Schema failures](../schemas/api#failures) and aggregate networking startup failures can also apply.
