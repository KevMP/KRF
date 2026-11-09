---
sidebar_position: 6
---

# ClientActionRuntime

`ClientActionRuntime` is the frozen client facade for Actor-specific Action routes and explicit typed Action requests.

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Actions = require(ReplicatedStorage.Packages.KRF.client.Action.ClientActionRuntime)
```

Public contract types are in `KRF.client.Action.types`. `ActorView` is the client Actor identity, not a server Actor or an Actor id string.

## Members

| Kind | Signature |
| --- | --- |
| Method | [`SetProfileSource(actor: ActorView, sourceId: string, profile: ControlProfile) -> (boolean, string?)`](#set-profile-source) |
| Method | [`RemoveProfileSource(actor: ActorView, sourceId: string) -> (boolean, string?)`](#remove-profile-source) |
| Method | [`SetControlledActor(actor: ActorView?) -> (boolean, string?)`](#set-controlled-actor) |
| Method | [`GetControlledActor() -> ActorView?`](#get-controlled-actor) |
| Method | [`GetEffectiveRoute(actor: ActorView, key: RouteKey) -> RouteQuerySnapshot?`](#get-effective-route) |
| Method | [`GetProfileSources(actor: ActorView) -> {ProfileSourceSnapshot}`](#get-profile-sources) |
| Method | [`RequestAction(actor: ActorView, actionId: string, parameters: any?) -> (number?, string?)`](#request-action) |
| Method | [`RequestStop(originalStartRequestId: number, parameters: any?) -> (number?, string?)`](#request-stop) |
| Method | [`RequestInterrupt(originalStartRequestId: number, reason: ActionInputInterruptReason) -> (number?, string?)`](#request-interrupt) |
| Method | [`RetireRequest(originalStartRequestId: number) -> (boolean, string?)`](#retire-request) |

## Methods

### `SetProfileSource(actor: ActorView, sourceId: string, profile: ControlProfile) -> (boolean, string?)` {#set-profile-source}

Atomically replaces one Actor's source-owned route profile. A profile supplies `routes` and optional integer `priority`; each route has `when`, `target`, optional `requiredContexts` and optional `dispatch` policy. A higher source priority wins an equivalent route key; equal priorities for the same key are rejected with `ProfilePriorityConflict`.

`when` is `{ kind = "Input", inputId, gesture }`, `{ kind = "Sequence", sequenceId }` or `{ kind = "Custom", recognizerId }`. A Fixed target supplies `actionId`; a Dynamic target supplies `resolve(ctx) -> ResolvedAction?`, returning `{ actionId, parameters? }` or nil. See the [Action input guide](/Action/action-input#route-a-slot-once).

Returns `true, nil` on success. Failure leaves the previous profile intact. Stable denials include `ClientNotReady`, `DispatchInProgress`, `ActorViewUnavailable`, `InvalidProfileSourceId`, `InvalidControlProfile`, `InvalidProfilePriority`, `InvalidRouteKey`, `InvalidRouteTarget`, `InvalidActionId`, `DuplicateRouteKey`, `InvalidRequiredContexts`, `InvalidDispatchPolicy`, `ProfileRouteLimitExceeded`, `RouteContextLimitExceeded`, `ProfileSourceLimitExceeded`, `ProfileActorLimitExceeded`, `ProfilePriorityConflict` and `ProfileDependencyMissing`.

### `RemoveProfileSource(actor: ActorView, sourceId: string) -> (boolean, string?)` {#remove-profile-source}

Removes this source's profile and invalidates affected automatic input ownership. Returns `true, nil` on success, including absent sources. Shares the readiness, Actor, source and dependency validation of `SetProfileSource`.

### `SetControlledActor(actor: ActorView?) -> (boolean, string?)` {#set-controlled-actor}

Selects the Actor whose routes dispatch; nil clears selection. Successful switching invalidates previous press/recognition ownership and applies captured Action invalidation policies. A held key does not become a new press on the next Actor.

Returns `true, nil` on success. Stable denials include `ClientNotReady`, `DispatchInProgress`, `ActorViewUnavailable`, `StaleActorSwitch`, `ActorSwitchGuardFailed`, `ActorSwitchGuardYielded` and `ActorSwitchCommitFailed`.

### `GetControlledActor() -> ActorView?` {#get-controlled-actor}

Returns the selected available ActorView, or nil when unselected, unavailable or not ready.

### `GetEffectiveRoute(actor: ActorView, key: RouteKey) -> RouteQuerySnapshot?` {#get-effective-route}

Returns a frozen `Mapped`, `Gated` or `Unmapped` snapshot without running a resolver. A mapped snapshot includes source, priority, target kind, optional fixed Action id, dispatch policy, required contexts, shadowed sources and continuity version. Returns nil for invalid keys, unavailable Actors or an unready client.

### `GetProfileSources(actor: ActorView) -> {ProfileSourceSnapshot}` {#get-profile-sources}

Returns frozen source summaries containing `sourceId`, `priority` and `routeCount`; returns an empty list when unavailable or unready.

### `RequestAction(actor: ActorView, actionId: string, parameters: any?) -> (number?, string?)` {#request-action}

Requests Start with explicit full parameters and returns its locally admitted original request id. Bypasses input policies and parameter producers. Retain this id for follow-ups; it is not a server sequence id or proof of server acceptance.

Stable local denials include `ClientNotReady`, `DispatchInProgress`, `ActionRequestUnregistered`, `ActorViewUnavailable`, `ActionRequestCapacityReached` and the payload failures below. Command readiness/capacity denials are shared with [CommandRuntime](/api/Networking/command-runtime).

### `RequestStop(originalStartRequestId: number, parameters: any?) -> (number?, string?)` {#request-stop}

Requests nonterminal Stop against the exact original Start and returns the follow-up's locally admitted request id. Supply full Stop parameters; no input producer or automatic failure fallback runs. Successful local admission retires matching automatic input ownership before another release can duplicate it.

Returns `ActionStartUnknown` when the original is unknown, retired or belongs to a previous client lifetime; `ActionStopUnavailable` when Stop is undeclared. Also shares readiness, reentrancy, payload and capacity denials. `ActionInputRequestInProgress` rejects a nested manual follow-up while the same automatic activation is already preparing one.

### `RequestInterrupt(originalStartRequestId: number, reason: ActionInputInterruptReason) -> (number?, string?)` {#request-interrupt}

Requests Interrupt against the exact original Start. Reasons are `"ActorSwitched"`, `"ClientShutdown"`, `"ContextDisabled"`, `"FocusLost"`, `"RouteInvalidated"` or `"StopPreparationFailed"`.

Shares Stop's readiness, original identity, reentrancy and capacity denials. Returns `ActionInterruptNotAllowed` without wire permission, or `ActionInterruptReasonInvalid` for an unsupported reason. Local admission does not prove server cancellation.

An Accepted Interrupt retires the original's follow-up authority, including a late Accepted result received during the command grace window. Unknown or Rejected Interrupts do not prove termination and retain that authority.

### `RetireRequest(originalStartRequestId: number) -> (boolean, string?)` {#retire-request}

Locally relinquishes the original request's follow-up authority. Sends no network command and does not Stop, Interrupt or End the server Action. Pending command results remain correlated. For an input-owned original, also detaches automatic ownership so a subsequent release cannot send a follow-up.

Returns `true, nil` on retirement. Returns `false, reason` with `ClientNotReady`, `DispatchInProgress`, `ActionStartUnknown` for an unknown or already retired original, or `ActionInputRequestInProgress` while the same automatic activation is preparing a request. Use when game code deliberately gives up further control; Accepted Stop alone remains nonterminal and does not release a direct original's authority.

### Shared payload denials

| Reason | Meaning |
| --- | --- |
| `ActionPayloadUnexpected` | Parameters supplied to a parameterless contract |
| `ActionPayloadInvalid` | Missing, extra, mistyped, non-finite or otherwise invalid schema data |
| `ActionPayloadTooLarge` | Encoded data exceeds the request payload budget |

## Related

- [Coordinated client controls](/Action/client-controls)

- [Action input](/Action/action-input)
- [Action requests](/Action/action-requests)
- [Client initialization](/api/Client/)
- [ActionController](./action-controller)
