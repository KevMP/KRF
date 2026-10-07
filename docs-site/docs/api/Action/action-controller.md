---
sidebar_position: 2
---

# Action Controller

`ActionController` owns one Actor's grants and active Action instances. Get it after the Actor is registered.

```lua
local actions = actor:GetController("ActionController") :: ActionTypes.ActionController
```

Import `ActionTypes` from `KRF.server.Action.types`. Public result and event shapes are in the [Action types reference](./action-types).

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

Returns a frozen list of effective Action ids in Action registry order.

### `RequestAction(actionId: string, parameters: any?) -> ActionRequestResult` {#request-action}

Requests one Action on this Actor. An accepted result is `{ accepted = true, sequenceId = number }`; a rejected result is `{ accepted = false, reason = string }`.

**Integration API.** Use for request-delivery integrations or occasional server-driven behavior. Normal Action authoring uses factories and callbacks; this method does not provide input integration.

Checks start requirements and atomically commits prepared costs and declarative effects with activation. Parameters are passed unchanged. Acceptance does not imply the instance is still active when the method returns.

| Rejection reason | Cause |
| --- | --- |
| `ActionControllerDestroyed` | The controller is destroying or destroyed. |
| `ActorDisabled` | The Actor is unavailable for a new request. |
| `ActionIdMustBeString` / `ActionIdCannotBeEmpty` | The Action id is invalid. |
| `UnknownActionId:<id>` | No loaded definition has this id. |
| `ActionNotGranted` | This Actor is not granted the Action. |
| `ActionRequiredTagMissing:<id>` | A required Tag is absent at preflight or final validation. |
| `ActionBlockedTagPresent:<id>` | A blocked Tag is present at preflight or final validation. |
| `ActionResourceControllerUnavailable` | A Resource-dependent request has no live ResourceController. |
| `ActionResourceNotAssigned:<id>` | A referenced Resource is not assigned. |
| `ActionResourceRequirementNotSatisfied:<id>` | An absolute or percentage threshold fails. |
| `ActionResourceRequirementRangeInvalid:<id>` | A percentage requirement has no positive usable range. |
| `ActionResourceCostRangeInvalid:<id>` | A percentage cost has invalid resolved bounds. |
| `ActionResourceMultiplierInvalid:<id>:<property>` | The multiplier Property is missing, non-finite, or negative. |
| `ActionResourceCostInvalid:<id>` | The effective cost is non-finite or negative. |
| `ActionResourcePlanningFailed:InsufficientResourceValue:<id>` | An effective cost exceeds available value above the minimum. |
| `ActionResourcePlanningFailed:InvalidResourceValue:<id>` | The prepared subtraction produces a non-finite current value. |
| `ActionTagActivationFailed:<id>` | A declarative Tag application cannot commit. No incoming Action or Tag effects remain. |
| `ActionFactoryFailed` / `ActionFactoryYielded` / `ActionFactoryInvalidResult` | The per-request factory errored, yielded, or returned an invalid Action implementation. No sequence id is consumed. |
| `ActionCanStartRejected` | `onCanStart` returned `false` without a usable custom reason. |
| `ActionCanStartFailed` / `ActionCanStartYielded` / `ActionCanStartInvalidResult` | The decision callback errored, attempted to yield, or returned a non-boolean first value. |
| `ActionLockConflict` | A conflicting owner did not permit preemption, or conflict planning remained unstable. |
| `ActionInterruptDecisionFailed` / `ActionInterruptDecisionYielded` / `ActionInterruptDecisionInvalidResult` | A conflicting owner's interruption hook errored, yielded, or returned a non-boolean value. |
| Game-defined string | `onCanStart` returned `false, reason` with a non-empty string. |

### `RequestStop(sequenceId: number, parameters: any?) -> (boolean, string?)` {#request-stop}

Calls the instance's optional `onStopRequested(ctx, request)` synchronously with an [ActionStopRequest](./action-types#action-stop-request). Returns `true, nil` for an active target, including when no hook exists or its error/yield is contained; no automatic termination occurs. Returns `false` with `ActionSequenceIdInvalid`, `ActionInstanceNotActive`, or `ActionControllerDestroyed` when the target is unavailable.

### `EndAction(sequenceId: number) -> (boolean, string?)` {#end-action}

Ends one active instance. Returns `false` with `ActionSequenceIdInvalid`, `ActionInstanceNotActive`, or `ActionControllerDestroyed` on failure.

Sequence ids supplied to Stop, End, or Interrupt must be finite positive integers. Successful End/Interrupt returns `true, nil`.

### `InterruptAction(sequenceId: number, reason: string) -> (boolean, string?)` {#interrupt-action}

Interrupts one active instance. The reason must be a non-empty string. Returns `false` with `ActionSequenceIdInvalid`, `ActionInterruptReasonInvalid`, `ActionInstanceNotActive`, or `ActionControllerDestroyed` on failure.

### `Destroy() -> ()` {#destroy}

Interrupts active instances with `ActionControllerDestroyed`, clears grants, and destroys controller events. Repeated calls are safe.

## Events

### `OnActionGrantChanged: Event<Actor, string, boolean>` {#on-action-grant-changed}

Fires when this Actor's effective grant for one Action changes. Arguments are the Actor, Action id, and new granted state.

### `OnActionStarted: Event<ActionLifecycleEvent>` {#on-action-started}

Fires when an Action request is accepted. Payload: [ActionLifecycleEvent](./action-types#lifecycle-events).

### `OnActionEnded: Event<ActionLifecycleEvent>` {#on-action-ended}

Fires when an active instance Ends. Payload: [ActionLifecycleEvent](./action-types#lifecycle-events).

### `OnActionInterrupted: Event<ActionInterruptedEvent>` {#on-action-interrupted}

Fires when an active instance is Interrupted. Payload and runtime interruption reasons: [ActionInterruptedEvent](./action-types#lifecycle-events).

## Related

- [Action types](./action-types)
- [ActionExecutionContext](./action-execution-context)
- [Actions Overview](/Action/actions-overview)
- [Action Lifecycle guide](/Action/action-lifecycle)
- [Action grants guide](/Action/action-grants)
- [Action updates guide](/Action/action-updates)
- [Action locks guide](/Action/action-locks)
- [Action Tags guide](/Action/action-tags)
- [Action Resources guide](/Action/action-resources)
- [Advanced Ordering & Reentrancy](/Action/action-ordering)
- [Action Registry](/api/Action/action-registry)
