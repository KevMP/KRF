---
sidebar_position: 3
---

# Action Runtime

`ActionController` owns the active Action instances for one Actor. `RequestAction` is its server-side entrypoint; KRF manages each accepted instance through termination. Input handling and networking are separate from this controller.

## The whole lifecycle

| Stage | What happens | What it means for the caller |
| --- | --- | --- |
| **Register** | `Server.Init` loads an Action factory and stores its static definition in `ActionRegistry`. | The Action exists in the registry, but no Actor can run it just because it is registered. |
| **Grant** | The Actor's `ActionController` receives an `autoGrant` baseline or explicit grant source. | That Actor may request the Action. Granting does not create an instance. |
| **Request and decide** | A server-side request reaches `ActionController`. KRF checks the Actor, grant, and start-time Tag requirements, calls the per-request factory and optional `onCanStart`, then resolves lock conflicts and revalidates. | A rejected request returns a reason; it creates no instance and consumes no sequence id. |
| **Accept and start** | KRF commits the instance, lifetime locks, and declarative Tags before issuing lifecycle signals, dispatching Tag and Property events, and beginning `onStart` if still active. | The request returns `accepted = true` and the sequence id, even if `onStart` immediately ends the instance. |
| **Remain active** | The instance holds its acquired locks. Optional `onUpdate` performs recurring work; `RequestStop` can call `onStopRequested`. | Returning from `onStart` or requesting Stop does not end the instance automatically. |
| **End or Interrupt** | An explicit End completes the instance; an Interrupt can come from game code, a failure, preemption, or controller destruction. KRF makes the instance inactive, releases its locks and remaining Action-owned active Tags, then dispatches the matching event and hook. | End and Interrupt are terminal for that instance. Returning from a callback does not trigger either transition. |

Destroying the controller Interrupts its active instances. Revoking a grant prevents later requests but does not terminate an instance already running under that grant. Several instances of the same Action can be active at once when their [lock claims](./action-locks) allow it.

## When a request reaches the controller

The server-side [`RequestAction`](/api/Action/action-controller#request-action) call is the boundary into the Action runtime. The system that receives a gameplay intent decides when to make that call; `ActionController` handles acceptance and the instance lifecycle. A direct request is useful for a server-driven Action, but is not a required input-handling pattern.

The Action must exist, be granted, satisfy its required and blocked Tags, pass its optional `onCanStart` decision, and acquire its declared locks. KRF calls its factory for this request, then uses that result's callbacks throughout the activation. The factory and `onCanStart` must finish synchronously without yielding. `onCanStart` receives a frozen `ActionStartContext` with `actor`, `actionId`, and the original `parameters`. It may return `false, "GameReason"` to reject with a game-defined reason. KRF rechecks Actor availability, grants, and Tags after decision callbacks, so reentrant changes cannot make an invalid request commit. A rejection creates no instance and consumes no sequence id.

`requiredTags`, `blockedTags`, and `resourceRequirements` are start-time checks against current authoritative state. Later changes do not automatically End or Interrupt a running Action. Preemption cannot bypass a currently failing requirement.

KRF checks Resource requirements and affordability before the per-request factory, then builds a fresh payment plan after `onCanStart` and interruption decisions. The final plan uses current Resource bounds and resolved multiplier Properties before removing preempted owners' Tags or applying incoming Tags. Those same-transaction effects cannot discount the prepared price or make a failing requirement pass.

Acceptance commits every prepared cost, owner preemption, incoming locks, Tags, final Property values, and derived Resource state before consumer callbacks. A rejection commits none of those incoming effects and consumes no sequence id. Explicit mutations made by decision callbacks remain game-owned and are not rolled back. Use declarative costs for acceptance-time payment rather than spending inside `onCanStart`.

Final valid bounds clamp the already-paid current value once. If final Property values produce invalid bounds, KRF retains the Resource's last valid min/max/regen state; the Action remains accepted and committed costs and current-value mutations remain committed. It does not repair bounds or roll back. End, Interrupt, hook failure, and controller destruction never refund costs.

Normal dispatch issues lifecycle signals, Tag events, Property notifications, then sorted net Resource notifications before terminal hooks and incoming `onStart`. Each affected Resource publishes at most one net change for the acceptance transaction; unchanged current/min/max publishes none. Property listeners can already read final Resource state. Reentrant calls may synchronously drain older pending notifications; event payloads describe their committed transition while getters read the latest state.

Request parameters are opaque server-side game data. KRF passes the same value to `onCanStart` and the accepted Action; it does not copy or serialize it. Validate client-originated data before calling this server API.

## Work with `ActionExecutionContext` {#execution-context}

KRF creates one frozen `ActionExecutionContext` for each accepted instance. It passes that same context to the instance's `onStart`, `onStopRequested`, `onUpdate`, `onEnd`, and `onInterrupt` callbacks, and to its `canBeInterruptedBy` decision when another Action claims a conflicting lock. `onCanStart` runs before acceptance and receives a smaller `ActionStartContext` without a sequence id or lifecycle methods.

| Context member | What it provides |
| --- | --- |
| `actor`, `actionId`, `sequenceId` | The Actor and identity of this activation. The sequence id distinguishes concurrent instances of the same Action. |
| `parameters` | The original value supplied with the start request. KRF does not copy or serialize it. |
| `ctx:IsActive()` | Whether this exact instance is still active. It is `false` inside `onEnd` and `onInterrupt`, because termination commits before those callbacks run. |
| `ctx:End()` | Normally completes this instance. Returns `true` on the first successful End, or `false, reason` if it cannot End. |
| `ctx:Interrupt(reason)` | Terminates this instance with a non-empty reason. Returns `true` on success, or `false, reason` if it cannot Interrupt. |
| `ctx:ClaimLocks(lockIds)` | Temporarily claims [scoped locks](./action-locks) while active. Returns a releasable claim or `nil, reason`. |

The context identifies and controls an instance; it is not a mutable state bag. Put private state inside the Action factory so callbacks from one activation share it without sharing it with other activations. An Action can retain its context to query or terminate its own instance later; a retained context cannot reactivate an instance after it ends.

## Stop, End, and Interrupt

| Operation | What it means |
| --- | --- |
| `RequestStop(sequenceId, parameters?)` | Delivers `onStopRequested(ctx, request)` to an active instance. It is a request, not a terminal transition. |
| `ctx:End()` or `EndAction(sequenceId)` | Completes one active instance normally, then dispatches `OnActionEnded` and `onEnd`. |
| `ctx:Interrupt(reason)` or `InterruptAction(sequenceId, reason)` | Terminates one active instance with a reason, then dispatches `OnActionInterrupted` and `onInterrupt`. |

`ctx:End()` targets the sequence id bound to that context. It is the same normal completion path as `actions:EndAction(sequenceId)`. On success, KRF first removes the instance from active state, releases all its lifetime and scoped locks, removes it from recurring updates, retires a suspended `onStart` invocation, and cleans up remaining Action-owned `activeTags` contributions. The normal post-commit order is `OnActionEnded`, Tag events, Property notifications, then `onEnd(ctx)` if defined. Reentrant mutations can issue older pending [Property notifications](../Property/property-runtime#changes) earlier. The call returns `true, nil`; a later End returns `false, "ActionInstanceNotActive"` while the controller still exists. Inside `onEnd`, `ctx:IsActive()` is already `false`.

`ctx:Interrupt(reason)` follows the same terminal order, using `OnActionInterrupted` and `onInterrupt(ctx, reason)` instead. Neither terminal hook can undo a committed transition. These hooks must finish without yielding; KRF contains errors and yields.

`RequestStop` calls its optional hook synchronously with `{ parameters = stopParameters }`. It can be called repeatedly while the instance remains active. Returning from `onStopRequested` leaves the instance active unless game code calls `ctx:End()` or `ctx:Interrupt(reason)`. Returning from `onStart` also leaves the instance active. For recurring work, an Action can define [`onUpdate`](./action-updates).

`ctx:End()` and `ctx:Interrupt()` do not return from the surrounding callback. Return explicitly when its remaining statements should not run.

## Hook and event order

All Action hooks are optional. The table shows when KRF calls each one if defined.

| Point in the lifecycle | Hook or event | When it runs |
| --- | --- | --- |
| Effective grant changes | `OnActionGrantChanged` | After `SetGrants` changes an Actor's effective grant. Initial `autoGrant` setup issues no event. This does not start or stop an instance. |
| Factory execution | Action factory | Once at startup for definition metadata, then once per request that passes the initial Actor and grant checks. Its per-request callbacks are captured for that request. |
| Request validation | `onCanStart(startContext)` | After the per-request factory returns, before an instance exists. A rejection issues no lifecycle event. |
| Lock conflict | `canBeInterruptedBy(ownerCtx, incoming)` | On a conflicting active owner during a request or scoped lock claim, after its static `interruptibleBy` allowlist permits the incoming Action and before preemption commits. Denial leaves the owners active. |
| Activation | `OnActionStarted`, then `onStart(ctx)` | After the instance and lifetime locks are committed. KRF fires Started before beginning `onStart` if the instance is still active. Returning from `onStart` does not End the instance. |
| Active updates | `onUpdate(ctx, deltaTime)` | Only while active, when the Action defines the hook; at most 20 times per second. An error or yield Interrupts a still-active instance with `ActionUpdateFailed`. |
| Stop request | `onStopRequested(ctx, request)` | Synchronously when `RequestStop` targets an active instance. There is no Stop event or automatic End. |
| Normal completion | `OnActionEnded`, then `onEnd(ctx)` | After the instance becomes inactive and releases its locks. The hook sees `ctx:IsActive() == false`. |
| Interruption | `OnActionInterrupted`, then `onInterrupt(ctx, reason)` | After the same terminal cleanup. This includes manual interruption, lock preemption, controller destruction, and an active `onStart` failure. |

Lifecycle events carry `actor`, `actionId`, and `sequenceId`; `OnActionInterrupted` also carries `reason`. Each instance has at most one terminal event: Ended or Interrupted. KRF fires each signal before invoking the corresponding hook, but signal listeners run through non-blocking scheduling. A listener is not guaranteed to finish before the hook or the controller call returns.

Lock preemption commits conflicting owners inactive, cleans their Action-owned Tags, and activates the incoming instance with its declarative Tags before callbacks. Normal dispatch issues the owners' Interrupted signals and the incoming Started signal, then Tag events followed by Property notifications. Owner interruption hooks run afterward in sequence-id order; incoming `onStart` runs only if the instance remains active. Started is always issued before an accepted instance's terminal signal, including when a listener reentrantly terminates it before its normal Started turn. Nested lifecycle calls remain synchronous. See [Action Tags](./action-tags) for the full transaction order.

Destroying the controller Interrupts every active instance with `ActionControllerDestroyed`, cleans their Action-owned Tags, and retires suspended starts. Tasks or connections created separately by game code remain game-owned. Later public Action mutations fail. Removing a grant by itself does not terminate an Action already running under that grant.

## Related

- [ActionController API](/api/Action/action-controller)
- [Action Grants](./action-grants)
- [Action Registry](./action-registry)
- [Action Updates](./action-updates)
- [Action Locks](./action-locks)
- [Action Tags](./action-tags)
