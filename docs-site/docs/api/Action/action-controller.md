---
sidebar_position: 2
---

# Action Controller

`ActionController` owns one Actor's grants and active Action instances. Get it after the Actor is registered.

```lua
local actions = actor:GetController("ActionController")
```

## Members

| Kind | Signature |
| --- | --- |
| Method | [`SetGrants(sourceId: string, actionIds: {string}) -> (boolean, string?)`](#set-grants) |
| Method | [`IsActionGranted(actionId: string) -> boolean`](#is-action-granted) |
| Method | [`GetGrantedActions() -> {string}`](#get-granted-actions) |
| Method | [`RequestAction(actionId: string, parameters: any?) -> ActionRequestResult`](#request-action) |
| Method | [`RequestStop(sequenceId: number, parameters: any?) -> (boolean, string?)`](#request-stop) |
| Method | [`EndAction(sequenceId: number) -> (boolean, string?)`](#end-action) |
| Method | [`InterruptAction(sequenceId: number, reason: string) -> (boolean, string?)`](#interrupt-action) |
| Method | [`Destroy() -> ()`](#destroy) |
| Event | [`OnActionGrantChanged: Event<Actor, string, boolean>`](#on-action-grant-changed) |
| Event | [`OnActionStarted: Event<ActionLifecycleEvent>`](#on-action-started) |
| Event | [`OnActionEnded: Event<ActionLifecycleEvent>`](#on-action-ended) |
| Event | [`OnActionInterrupted: Event<ActionInterruptedEvent>`](#on-action-interrupted) |

## Methods

### `SetGrants(sourceId: string, actionIds: {string}) -> (boolean, string?)` {#set-grants}

Atomically replaces one source's complete Action set. Returns `true, nil` on success, including an unchanged set or an empty-set clear.

| Failure reason | Cause |
| --- | --- |
| `ActionGrantSourceIdMustBeString` | The source id is not a string. |
| `ActionGrantSourceIdCannotBeEmpty` | The source id is empty. |
| `ActionGrantIdsMustBeTable` | The Action ids are not a table. |
| `ActionGrantIdsMustBeArray` | The table is not a dense array. |
| `ActionGrantIdMustBeString` | An entry is not a string. |
| `ActionGrantIdCannotBeEmpty` | An entry is empty. |
| `UnknownActionId:<id>` | An Action id is absent from the loaded registry. |
| `ActionControllerDestroyed` | The controller has been destroyed. |

Failure leaves all source and effective grants unchanged.

### `IsActionGranted(actionId: string) -> boolean` {#is-action-granted}

Returns whether the Action is effectively granted to this Actor; an unknown id returns `false`.

### `GetGrantedActions() -> {string}` {#get-granted-actions}

Returns a frozen list of effective Action ids in Action catalog order.

### `RequestAction(actionId: string, parameters: any?) -> ActionRequestResult` {#request-action}

Requests one Action on this Actor. An accepted result is `{ accepted = true, sequenceId = number }`; a rejected result is `{ accepted = false, reason = string }`.

| Rejection reason | Cause |
| --- | --- |
| `ActionControllerDestroyed` | The controller is destroying or destroyed. |
| `ActorDisabled` | The Actor is unavailable for a new request. |
| `ActionIdMustBeString` / `ActionIdCannotBeEmpty` | The Action id is invalid. |
| `UnknownActionId:<id>` | No loaded definition has this id. |
| `ActionNotGranted` | This Actor is not granted the Action. |
| `ActionFactoryFailed` / `ActionFactoryYielded` / `ActionFactoryInvalidResult` | The per-request factory errored, yielded, or returned an invalid Action implementation. No sequence id is consumed. |
| `ActionCanStartRejected` | `onCanStart` returned `false` without a usable custom reason. |
| `ActionCanStartFailed` / `ActionCanStartYielded` / `ActionCanStartInvalidResult` | The decision callback errored, attempted to yield, or returned a non-boolean first value. |
| Game-defined string | `onCanStart` returned `false, reason` with a non-empty string. |

### `RequestStop(sequenceId: number, parameters: any?) -> (boolean, string?)` {#request-stop}

Calls that instance's optional `onStopRequested(ctx, { parameters = parameters })` synchronously. The callback must not yield. Its error or yield is contained. Repeated requests are allowed while active; KRF does not End or Interrupt the Action automatically. Returns `false` with `ActionSequenceIdInvalid`, `ActionInstanceNotActive`, or `ActionControllerDestroyed` when the target is unavailable.

### `EndAction(sequenceId: number) -> (boolean, string?)` {#end-action}

Ends one active instance. Returns `false` with `ActionSequenceIdInvalid`, `ActionInstanceNotActive`, or `ActionControllerDestroyed` on failure.

### `InterruptAction(sequenceId: number, reason: string) -> (boolean, string?)` {#interrupt-action}

Interrupts one active instance. The reason must be a non-empty string. Returns `false` with `ActionSequenceIdInvalid`, `ActionInterruptReasonInvalid`, `ActionInstanceNotActive`, or `ActionControllerDestroyed` on failure.

### `Destroy() -> ()` {#destroy}

Interrupts active instances with `ActionControllerDestroyed`, clears grants, and destroys controller events. Repeated calls are safe.

## Events

### `OnActionGrantChanged: Event<Actor, string, boolean>` {#on-action-grant-changed}

Fires when this Actor's effective grant for one Action changes. Arguments are the Actor, Action id, and new granted state.

### `OnActionStarted: Event<ActionLifecycleEvent>` {#on-action-started}

Fires when an Action request is accepted. The payload contains `actor`, `actionId`, and `sequenceId`.

### `OnActionEnded: Event<ActionLifecycleEvent>` {#on-action-ended}

Fires when an active instance Ends. The payload contains `actor`, `actionId`, and `sequenceId`.

### `OnActionInterrupted: Event<ActionInterruptedEvent>` {#on-action-interrupted}

Fires when an active instance is Interrupted. The payload contains `actor`, `actionId`, `sequenceId`, and `reason`; an update error or yield uses `ActionUpdateFailed`.

## Related

- [Run Actions guide](/Action/action-lifecycle)
- [Action grants guide](/Action/action-grants)
- [Action updates guide](/Action/action-updates)
- [Action Registry](/api/Action/action-registry)
