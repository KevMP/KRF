---
sidebar_position: 4
---

# Action Lifecycle

`ActionController` creates and terminates activations for one Actor. KRF owns acceptance and terminal cleanup, while authored callbacks supply game behavior.

## Request, run, terminate

1. **Request:** check Actor availability, registered identity, grant, Tags, and Resources. A qualifying request gets fresh factory callbacks and an optional `onCanStart` decision.
2. **Accept:** resolve lock preemption, revalidate availability, and commit upfront costs, owner termination, incoming locks, declarative Tags, and derived state together.
3. **Run:** issue Started and begin `onStart` if still active. Optional `onUpdate` supplies recurring work. Returning from `onStart` leaves the Action active.
4. **Terminate:** End or Interrupt makes the activation inactive, releases all locks, removes recurring updates, retires suspended `onStart`, and cleans remaining Action-owned active Tag contributions before terminal callbacks.

A rejection creates no activation, emits no Started event, and consumes no sequence id. An accepted result remains accepted even if a listener or `onStart` immediately terminates it. Several activations of the same Action can coexist when their locks allow it.

[`RequestAction`](/api/Action/action-controller#request-action) is the low-level server boundary used by integrations and occasional server-driven behavior. An accepted result carries the activation's `sequenceId`; a rejected result carries its reason. Action authors normally work through definitions and callbacks. Input integration is outside this guide.

Sequence ids are positive integers scoped to one controller and allocated in acceptance commit order. Parameters are passed unchanged, without copying or serialization. Context tables are frozen; a table supplied as `parameters` is not deep-frozen by KRF.

Start requirements do not continuously enforce themselves. Losing a grant, required Tag, or Resource threshold later does not automatically terminate an activation. Game code can react through events or updates.

## Work with the execution context {#execution-context}

All accepted callbacks share one `ActionExecutionContext`, carrying `actor`, `actionId`, `sequenceId`, and original `parameters`. It exposes `IsActive`, `End`, `Interrupt`, and `ClaimLocks`; see the [context API](/api/Action/action-execution-context) for exact contracts.

Keep private state in [factory-local variables](./action-registry#keep-activation-state-in-lexical-locals). The context identifies and controls the activation; it has no `state` field. A retained context cannot reactivate a terminated Action.

After calling `End` or `Interrupt`, return explicitly if subsequent callback statements should not execute. When a callback calls another KRF operation that can trigger consumer callbacks, recheck `ctx:IsActive()` before continuing gameplay work.

## Stop, End, and Interrupt

| Intent | Operation | Behavior |
| --- | --- | --- |
| Ask a held Action to release | `actions:RequestStop(sequenceId, parameters?)` | Calls optional `onStopRequested(ctx, { parameters = ... })` synchronously. It can be repeated and does not automatically terminate. |
| Complete normally | `ctx:End()` / `actions:EndAction(sequenceId)` | Terminal completion; emits Ended and calls optional `onEnd`. |
| Cancel or disrupt | `ctx:Interrupt(reason)` / `actions:InterruptAction(sequenceId, reason)` | Terminal interruption; emits Interrupted and calls optional `onInterrupt`. Reason must be a non-empty string. |

Stop parameters are separate from start parameters. KRF accepts a Stop request even when no Stop hook exists. There is no Stop lifecycle event.

End and Interrupt are terminal alternatives: an activation has at most one terminal event. `ctx:IsActive()` is already `false` inside `onEnd` and `onInterrupt`. Cleanup hooks cannot undo termination. Costs are never automatically refunded; `appliedTags` follow ordinary Tag lifetime rules.

## Hook contracts {#hook-contracts}

All hooks are optional. Their presence does not determine lifetime; End and Interrupt do.

| Callback | Yieldability | Return/failure behavior |
| --- | --- | --- |
| `ActionFactory()` | Non-yielding | Returns a definition. Failure/yield fails startup or rejects the request. |
| `onCanStart(startCtx)` | Non-yielding | Returns `(boolean, string?)`; `false` rejects, optionally with a game reason. Error, yield, or non-boolean decision rejects. |
| `canBeInterruptedBy(ownerCtx, incoming)` | Non-yielding | Returns a boolean, narrowing the owner's static allowlist. Failure/yield/invalid decision denies preemption. |
| `onStart(ctx)` | May remain suspended for the Action lifetime | Returning leaves it active. Error Interrupts a still-active Action with `ActionStartFailed`. External termination retires the suspended invocation. |
| `onStopRequested(ctx, request)` | Non-yielding | Error/yield is contained; no automatic End or Interrupt. |
| `onUpdate(ctx, deltaTime)` | Non-yielding | Error/yield Interrupts a still-active Action with `ActionUpdateFailed`. |
| `onEnd(ctx)` / `onInterrupt(ctx, reason)` | Non-yielding, failure-contained | Errors/yields cannot reverse the committed transition or prevent other activations' cleanup. |

KRF cancels yielded invocations of non-yielding hooks. Separately spawned tasks and connections remain game-owned: release them in both terminal hooks. Put shared cleanup in one local function so End and Interrupt follow the same resource ownership rules.

## Observe lifecycle

`OnActionStarted`, `OnActionEnded`, and `OnActionInterrupted` report activation identity; Interrupted also includes the reason. KRF issues Started before that activation's terminal signal and issues the corresponding signal before its hook. Signal issuance does not guarantee that every listener finishes before a hook or controller call returns.

The consumer guarantee is committed state before callbacks. Read current Tags, Properties, Resources, and context activity rather than reconstructing state from event order. The canonical [Advanced Ordering & Reentrancy](./action-ordering) page documents the detailed transaction and nested-notification guarantees.

## Teardown

Destroying `ActionController` Interrupts every active activation with `ActionControllerDestroyed`; all are inactive before teardown callbacks. Later public mutations fail. Revoking grants alone does not do this.

Next: [Action Tags](./action-tags). Exact returns and event payloads: [ActionController API](/api/Action/action-controller), [Action types](/api/Action/action-types).
