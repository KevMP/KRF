---
title: Actions API
---

# Actions API

## ActionDefinition and ActionFactory

```lua
type ActionFactory = () -> KRF.ActionDefinition
```

| Definition field | Type | Default / constraint |
| --- | --- | --- |
| `id` | `string` | Required unique non-empty ID |
| `visibility` | `"ServerOnly" \| "ClientVisible"` | Required |
| `autoGrant` | `boolean?` | `false` |
| `requiredTags`, `blockedTags` | `{ string }?` | Empty; registered IDs |
| `activeTags`, `appliedTags` | `{ string \| { id: string, duration: number? } }?` | Empty; registered Tag IDs and positive finite duration overrides |
| `resourceRequirements` | `{ [string]: ActionResourceRequirement }?` | Empty; registered Resource IDs |
| `costs` | `{ [string]: number \| ActionResourceCost }?` | Empty; registered Resource IDs |
| `locks` | `{ string }?` | Empty; non-empty lock names |
| `interruptibleBy` | `{ string }?` | Empty; registered Action IDs |
| Callbacks | Functions below | All optional |

There is no `kind`, built-in phase, duration or automatic completion field. Generator recipes produce ordinary factories and callbacks.

Tag applications follow the registered duplicate policy. `activeTags` cleanup removes only applications created by that activation and still owned by it. Ignored duplicates and refreshes of existing applications do not transfer ownership; a later external refresh can invalidate that cleanup ownership. See [Tag ownership](../tags/guide#let-an-action-own-a-status).

### Resource requirements and costs {#resource-requirements-and-costs}

`ActionResourceRequirement` allows inclusive `min`, `max`, `minPercent` and `maxPercent` checks. Supply at least one finite numeric threshold. Absolute and percentage lower bounds must not exceed their matching upper bounds. Percent thresholds are fractions in `[0, 1]` of `(current - min) / (max - min)` and require a positive usable range. All supplied checks must pass.

A numeric cost is shorthand for `{ amount = number }`. A structured `ActionResourceCost` has exactly one positive finite `amount` or `percent`, plus optional `multiplierProperty: string`. Cost percentages may exceed 1.

```text
percentage amount = (resolved max - resolved min) * percent
effective amount = amount * resolved multiplier, when supplied
```

The multiplier Property must be registered, assigned on the Actor, finite and non-negative. Zero permits a free effective cost. Requests don't assign missing Resources or multiplier Properties. Multiple costs are prepared and committed together; a later same-transaction Tag change doesn't re-price the fixed accepted plan.

### Callbacks {#callbacks}

| Signature | Behavior / failure |
| --- | --- |
| `onCanStart(context: ActionStartContext) -> (boolean, string?)` | Non-yielding decision; false rejects with its reason; error/yield/invalid result rejects |
| `onStart(context: ActionExecutionContext) -> ()` | May suspend while active; KRF cancels the suspended coroutine on termination; returning doesn't End; error interrupts with `ActionStartFailed` |
| `onStopRequested(context: ActionExecutionContext, request: ActionStopRequest) -> ()` | Synchronous, nonterminal; failure is contained without automatic termination |
| `onUpdate(context: ActionExecutionContext, deltaTime: number) -> ()` | Non-yielding, elapsed seconds per activation; error/yield interrupts with `ActionUpdateFailed` |
| `onEnd(context: ActionExecutionContext) -> ()` | Non-yielding terminal cleanup; failure can't reverse End |
| `onInterrupt(context: ActionExecutionContext, reason: string) -> ()` | Non-yielding terminal cleanup; failure can't reverse Interrupt |
| `canBeInterruptedBy(context: ActionExecutionContext, incoming: ActionInterruptionContext) -> boolean` | Non-yielding; narrows the owner's static allowlist; failure denies preemption |

Start and interruption contexts contain `actor`, `actionId` and optional original `parameters`. `ActionStopRequest` contains optional `parameters` for Stop, separate from the start payload. Context records are frozen; server-direct payload tables are passed unchanged, not deep-copied. Shared request schemas validate client traffic; server-direct callers own their payload's shape and validation.

## ActionExecutionContext

Fields: `actor: Actor`, `actionId: string`, `sequenceId: number`, `parameters: any?`.

| Signature | Contract |
| --- | --- |
| `context:IsActive() -> boolean` | Current activation state, including inside callbacks |
| `context:End() -> (boolean, string?)` | Completes this activation |
| `context:Interrupt(reason: string) -> (boolean, string?)` | Cancels it; reason must be non-empty |
| `context:ClaimLocks(lockIds: { string }) -> (LockClaim?, string?)` | Acquires all requested locks or none |
| `claim:Release() -> ()` | Idempotently releases this scoped claim only |

`lockIds` must be a dense array of distinct nonempty strings. Releasing a claim leaves lifetime locks and other claims intact. Failed claims don't terminate the claimant. Owner callbacks can terminate it before a successful claim call returns, so check `IsActive` before subsequent game work. Termination releases all claims. Claim failures include `ActionInstanceNotActive`, `ActionLockRequestInvalid`, `ActionLockClaimDenied`, and interruption-decision failures.

## ActionController

```lua
local actions = actor:GetController("ActionController") :: KRF.ActionController
```

### Grants

```lua
actions:SetGrants(sourceId: string, actionIds: { string }) -> (boolean, string?)
actions:IsActionGranted(actionId: string) -> boolean
actions:GetGrantedActions() -> { string }
```

SetGrants atomically replaces one source's full set; an empty array clears it. Returns `true, nil`, including no-ops. Invalid input leaves every source and effective grant unchanged. GetGrantedActions returns a frozen array in registry order; unknown IDs query false.

| Grant failure | Cause |
| --- | --- |
| `ActionGrantSourceIdMustBeString`, `ActionGrantSourceIdCannotBeEmpty` | Invalid source |
| `ActionGrantIdsMustBeTable`, `ActionGrantIdsMustBeArray` | Invalid dense array |
| `ActionGrantIdMustBeString`, `ActionGrantIdCannotBeEmpty` | Invalid entry |
| `UnknownActionId:<id>` | Unregistered Action |
| `ActionControllerDestroyed` | Teardown |

### RequestAction

```lua
actions:RequestAction(actionId: string, parameters: any?) -> KRF.ActionRequestResult
```

Returns `{ accepted = true, sequenceId = number }` or `{ accepted = false, reason = string }`. Sequence IDs are positive per-Actor integers allocated only by accepted starts. Acceptance doesn't guarantee the activation is still running when the call returns.

Multiple activations of the same Action ID are allowed unless their locks conflict. Retain the sequence ID when later server code needs to stop or terminate one exact activation.

| Rejection / family | Cause |
| --- | --- |
| `ActorDisabled`, `ActionControllerDestroyed` | Actor or controller unavailable |
| `ActionIdMustBeString`, `ActionIdCannotBeEmpty`, `UnknownActionId:<id>` | Invalid identity |
| `ActionNotGranted` | No effective grant |
| `ActionRequiredTagMissing:<id>`, `ActionBlockedTagPresent:<id>` | Tag gate |
| `ActionResourceControllerUnavailable`, `ActionResourceNotAssigned:<id>` | Missing Resource state |
| `ActionResourceRequirementNotSatisfied:<id>`, `ActionResourceRequirementRangeInvalid:<id>` | Threshold / percentage range |
| `ActionResourceCostRangeInvalid:<id>`, `ActionResourceCostInvalid:<id>`, `ActionResourceMultiplierInvalid:<id>:<property>` | Invalid resolved cost |
| `ActionResourcePlanningFailed:<reason>` | Resource payment cannot be prepared, including insufficient value |
| `ActionFactoryFailed`, `ActionFactoryYielded`, `ActionFactoryInvalidResult` | Execution factory failure |
| `ActionCanStartFailed`, `ActionCanStartYielded`, `ActionCanStartInvalidResult`, `ActionCanStartRejected` | Start decision failure; an authored reason can replace generic rejection |
| `ActionLockConflict` | A conflicting owner disallows preemption |
| `ActionInterruptDecisionFailed`, `ActionInterruptDecisionYielded`, `ActionInterruptDecisionInvalidResult` | Conflicting owner's decision failure |
| `ActionTagActivationFailed:<id>` | Declarative Tag cannot be installed |
| `ActionSequenceIdExhausted`, `ActionVisibleInstanceLimitReached` | Activation capacity exhausted |

Rejection doesn't roll back explicit mutations made by authored decision callbacks. A publication failure after authority has committed can propagate an error after required notification/cleanup; it doesn't undo payment or acceptance.

### Stop and termination

```lua
actions:RequestStop(sequenceId: number, parameters: any?) -> (boolean, string?)
actions:EndAction(sequenceId: number) -> (boolean, string?)
actions:InterruptAction(sequenceId: number, reason: string) -> (boolean, string?)
actions:Destroy() -> ()
```

Stop invokes the optional callback synchronously and doesn't terminate by itself. Server-direct Stop can be repeated; the client request protocol separately restricts follow-up delivery. End and Interrupt are terminal alternatives. Destroy interrupts all active instances with `ActionControllerDestroyed`, clears grants and events, and is idempotent.

Sequence IDs must be integers from 1 to 4,294,967,295. Failure returns `false` with `ActionSequenceIdInvalid`, `ActionInstanceNotActive` or `ActionControllerDestroyed`; Interrupt additionally rejects `ActionInterruptReasonInvalid`. A valid Stop returns success even when its callback is absent or fails without terminating.

### Events

| Event | Arguments |
| --- | --- |
| `OnActionGrantChanged` | `(actor: Actor, actionId: string, isGranted: boolean)` |
| `OnActionStarted`, `OnActionEnded` | `{ actor: Actor, actionId: string, sequenceId: number }` |
| `OnActionInterrupted` | Same identity plus `reason: string` |

State is committed before notification. Started is issued before this activation's terminal event; each lifecycle event is issued before its matching hook. Subscriber completion isn't a barrier for other callbacks.

## ActionRegistry

Server-side dot calls on `KRF.ActionRegistry`:

| Signature | Result |
| --- | --- |
| `Get(id: string) -> LoadedActionDefinition?` | Frozen definition or nil |
| `GetAll() -> {LoadedActionDefinition}` | Frozen array in catalog order |
| `GetAllById() -> {[string]: LoadedActionDefinition}` | Frozen lookup map |
| `IsLoaded() -> boolean` | Whether startup published the catalog |

Loaded definitions contain normalized static fields, not per-activation callbacks or private state. Use `Server.Init` to load factories. Game code doesn't call registry Prepare, Publish or CreateExecution.

### Definition failures

| Reasons / family | Cause |
| --- | --- |
| `ActionDefinitionsMustBeTable`, `ActionDefinitionsMustBeArray` | Invalid factory catalog |
| `ActionFactoryMustBeFunction`, `ActionFactoryFailed`, `ActionFactoryYielded` | Invalid or failing startup factory |
| `ActionDefinitionMissing`, `ActionDefinitionMustBeTable` | Invalid returned definition |
| `ActionIdMissing`, `ActionIdMustBeString`, `ActionIdCannotBeEmpty`, `ActionIdAlreadyRegistered` | Invalid or duplicate identity |
| `ActionFieldMustBeString`, `ActionFieldUnsupported:<field>` | Unknown declaration field |
| `ActionVisibilityMissing`, `ActionVisibilityMustBeString`, `ActionVisibilityInvalid` | Missing or invalid visibility |
| `ActionRequiredAndBlockedTagsOverlap:<id>` | Contradictory Tag gates |

Array, reference, callback and Resource validators also report field-specific reasons for invalid types, repeated entries, unknown IDs, duration overrides and costs. A syntactically valid factory can still fail execution-time creation; that rejection appears in `RequestAction` above.

See [Actions](./guide), [client Action API](./client-api) and [ActionsView](../actors/client-views-api#actionsview).
