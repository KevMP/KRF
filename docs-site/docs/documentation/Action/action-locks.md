---
sidebar_position: 7
---

# Locks & Preemption

Locks express exclusive needs of active Actions on one Actor, such as `Movement` or `Hands`. `ActionController` acquires and releases them; game code declares which current owners may be preempted.

| Surface | Use |
| --- | --- |
| `locks` | Hold a lock for the whole active lifetime. |
| `interruptibleBy` | Exact Action ids allowed to preempt this owner when locks conflict. |
| `canBeInterruptedBy(ctx, incoming)` | Optional owner decision narrowing that static allowlist. |
| `ctx:ClaimLocks(lockIds)` | Acquire a releasable claim for one phase of an activation. |

Lock ids are opaque, non-empty, game-defined strings. There is no registry for lock names, priority system, wait queue, or implicit rule against concurrent activations of the same Action. Exclusivity comes from conflicting claims.

## The current owner decides

To let Dodge replace Sprint, both declare `locks = { "Movement" }`, and **Sprint** declares `interruptibleBy = { "Action.Dodge" }`. All referenced Action ids must exist in the startup catalog. A self-reference permits the same Action id to preempt an earlier activation.

Every distinct conflicting owner must permit preemption. Its loaded allowlist must include the incoming id; its captured `canBeInterruptedBy`, if present, must also return `true`. The hook cannot expand the allowlist. It can read factory-local state, for example to deny interruption during a committed attack phase.

```lua
-- Fragment inside an owner's factory; committedPhase is a factory-local boolean.
interruptibleBy = { "Action.Dodge" },
canBeInterruptedBy = function(
	_ctx: ActionTypes.ActionExecutionContext,
	_incoming: ActionTypes.ActionInterruptionContext
): boolean
	return not committedPhase
end,
```

The hook is non-yielding. `incoming` identifies the incoming Actor, Action id, and original start parameters. Error, yield, or a non-boolean decision rejects the request/claim. A denial commits no planned preemptions or incoming claims; explicit mutations performed by the decision callback itself are not rolled back.

On acceptance, KRF Interrupts each conflicting owner as a whole with `ActionLockPreempted` and commits incoming ownership before consumer callbacks. Preemption does not bypass Tag or Resource gates. Detailed decision retries and dispatch order live in [Advanced Ordering & Reentrancy](./action-ordering).

Explicit `ctx:Interrupt` and `InterruptAction` bypass lock interruption policy: use them for game-directed cancellation.

## Temporary claims

Use `ClaimLocks` when exclusivity is needed for only part of an already-active Action. It returns a claim after acquiring every requested lock, or a reason without acquiring any. A failed claim does not automatically terminate the claimant.

```lua
-- Inside onStart; ActionTypes comes from KRF.server.Action.types.
local claim, reason = ctx:ClaimLocks({ "Hands" })
if claim == nil then
	warn(`Hands unavailable: {reason}`)
	ctx:End()
	return
end
if not ctx:IsActive() then
	claim:Release()
	return
end
-- Perform this phase's work here.
claim:Release()
-- The Action can continue without this scoped claim.
```

Claim preemption uses the claiming activation's Action id and original start parameters. Owner callbacks can terminate the claimant before a successful call returns, so check activity before doing work.

An activation may own a lock through its lifetime declaration and several scoped claims. Releasing one claim removes only that claim's ownership reason. `Release` is idempotent and safe after termination; End, Interrupt, and destruction release all outstanding claims before cleanup hooks.

Exact methods and failures: [ActionExecutionContext / LockClaim API](/api/Action/action-execution-context). Next: [Action Updates](./action-updates).
