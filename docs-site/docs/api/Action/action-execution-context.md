---
sidebar_position: 4
---

# Action Execution Context

`ActionExecutionContext` identifies one accepted activation and exposes its lifecycle and scoped-lock capabilities. KRF passes it to that activation's callbacks; see [public types](./action-types#action-execution-context) for its frozen shape.

```lua
-- Received as a callback argument, for example:
onStart = function(ctx: ActionTypes.ActionExecutionContext): ()
```

## Members

| Kind | Signature |
| --- | --- |
| Property | [`actor: Actor`](#identity) |
| Property | [`actionId: string`](#identity) |
| Property | [`sequenceId: number`](#identity) |
| Property | [`parameters: any?`](#parameters) |
| Method | [`IsActive() -> boolean`](#is-active) |
| Method | [`End() -> (boolean, string?)`](#end) |
| Method | [`Interrupt(reason: string) -> (boolean, string?)`](#interrupt) |
| Method | [`ClaimLocks(lockIds: {string}) -> (LockClaim?, string?)`](#claim-locks) |
| LockClaim method | [`Release() -> ()`](#release) |

## Properties

### `actor: Actor`, `actionId: string`, `sequenceId: number` {#identity}

Read-only identity of this activation. Sequence id is a positive integer unique within this Actor's controller.

### `parameters: any?` {#parameters}

Original start-request value, passed without copying; read-only context membership does not freeze nested parameter data.

## Methods

### `IsActive() -> boolean` {#is-active}

Returns whether this exact activation remains active; false during terminal hooks and after teardown.

### `End() -> (boolean, string?)` {#end}

Normally completes this activation through the same path as `EndAction(sequenceId)`. Returns `true, nil` on success, or `false, "ActionInstanceNotActive"` / `false, "ActionControllerDestroyed"`.

### `Interrupt(reason: string) -> (boolean, string?)` {#interrupt}

Interrupts this activation through the same path as `InterruptAction(sequenceId, reason)`. Returns `true, nil` on success; failure reasons are `ActionInterruptReasonInvalid`, `ActionInstanceNotActive`, or `ActionControllerDestroyed`. Reason must be a non-empty string.

### `ClaimLocks(lockIds: {string}) -> (LockClaim?, string?)` {#claim-locks}

Acquires every requested scoped lock, returning a frozen `LockClaim, nil`, or `nil, reason` without partial acquisition. The list must be a dense array of unique, non-empty strings; an empty array is valid.

| Failure reason | Cause |
| --- | --- |
| `ActionInstanceNotActive` | Claimant is inactive, including termination during owner decisions. |
| `ActionLockRequestInvalid` | Malformed lock list or invalid/duplicate id. |
| `ActionLockClaimDenied` | Owner denies preemption or conflict planning remains unstable. |
| `ActionInterruptDecisionFailed` | Owner decision errors. |
| `ActionInterruptDecisionYielded` | Owner decision attempts to yield. |
| `ActionInterruptDecisionInvalidResult` | Owner decision returns a non-boolean value. |

Failure does not automatically terminate the claimant. Success records an acquisition commit; callbacks may have terminated the claimant before the method returns. Use `IsActive` to check current activity.

### `LockClaim:Release() -> ()` {#release}

Releases only this claim's ownership reasons. Repeated calls and calls after activation termination are safe. Lifetime declarations and other claims on the same locks remain effective.

## Related

- [Action types](./action-types)
- [ActionController](./action-controller)
- [Action Lifecycle](/Action/action-lifecycle)
- [Locks & Preemption](/Action/action-locks)
- [Advanced Ordering & Reentrancy](/Action/action-ordering)
