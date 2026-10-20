---
sidebar_position: 3
---

# Action Types

Public Action types describe authored definitions, callback contexts, request results, and lifecycle payloads. Import them from the server Action types module.

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ActionTypes = require(ReplicatedStorage.Packages.KRF.server.Action.types)
```

`Actor` below denotes `KRF.server.Actor.types.Actor`. Context method contracts are in the [execution context reference](./action-execution-context); controller methods and rejection strings are in the [controller reference](./action-controller).

## Members

| Type | Contract |
| --- | --- |
| [`ActionFactory = () -> ActionDefinition`](#action-factory) | Non-yielding definition factory. |
| [`ActionDefinition`](#action-definition) | Authored metadata and optional callbacks. |
| [`ActionVisibility = "ServerOnly" \| "ClientVisible"`](#action-visibility) | Required visibility metadata. |
| [`ActionTagApplication = string \| ActionTagApplicationOptions`](#action-tag-application) | Declarative Tag application. |
| [`ActionResourceRequirement`](#action-resource-requirement) | Inclusive Resource thresholds. |
| [`ActionResourceCost`](#action-resource-cost) | Fixed/percentage cost and optional multiplier. |
| [`OnCanStart`, `OnStart`, `OnStopRequested`, `OnUpdate`, `OnEnd`, `OnInterrupt`, `CanBeInterruptedBy`](#callbacks) | Callback aliases. |
| [`ActionStartContext`](#action-start-context) | Pre-acceptance identity and parameters. |
| [`ActionExecutionContext`](#action-execution-context) | Accepted activation identity and capabilities. |
| [`ActionInterruptionContext`](#action-interruption-context) | Incoming Action identity for owner decisions. |
| [`ActionStopRequest`](#action-stop-request) | Stop-specific parameters. |
| [`LockClaim`](#lock-claim) | Releasable scoped lock ownership. |
| [`ActionRequestAccepted`, `ActionRequestRejected`, `ActionRequestResult`](#action-request-result) | Discriminated request result. |
| [`ActionLifecycleEvent`, `ActionInterruptedEvent`](#lifecycle-events) | Lifecycle signal payloads. |

## ActionFactory {#action-factory}

Called once at startup for metadata, then for requests passing initial Actor/identity/grant/Tag/Resource checks to obtain fresh callbacks. Must not yield. See [factory authoring](/Action/action-registry).

## ActionDefinition {#action-definition}

| Field | Constraint/default |
| --- | --- |
| `id` | Unique, non-empty string. Per-request result must match the requested id. |
| `visibility` | Required supported visibility literal on every result. |
| `autoGrant` | Boolean; defaults to `false`. |
| `requiredTags`, `blockedTags` | Dense arrays of unique, non-empty registered Tag ids. Cannot overlap each other. Default empty. |
| `activeTags`, `appliedTags` | Dense ordered arrays of registered applications. Repeated Tag ids are allowed. Default empty. |
| `resourceRequirements`, `costs` | Maps keyed by non-empty registered Resource ids; default empty. Entries use the constraints below. |
| `locks` | Dense array of unique, non-empty opaque lock ids. Default empty. |
| `interruptibleBy` | Dense array of unique, non-empty registered Action ids; forward/self references allowed. Default empty. |
| `onCanStart`, `onStart`, `onStopRequested`, `onUpdate`, `onEnd`, `onInterrupt`, `canBeInterruptedBy` | Optional functions; see [callback signatures](#callbacks). |

Unsupported fields are rejected. Static metadata is validated and copied at startup. Per-request validation checks the result table, matching id, supported visibility, supported field names, and callback types; it does not replace loaded metadata with request-result fields.

## ActionVisibility {#action-visibility}

`"ServerOnly"` or `"ClientVisible"`.

`ClientVisible` publishes current active identities and lifecycle occurrences through [ActionsView](/api/Actor/actions-view). `ServerOnly` ids are excluded from the client protocol; parameters, interruption reasons, grants and locks remain server-only in both cases.

## ActionTagApplication / ActionTagApplicationOptions {#action-tag-application}

Supply a registered Tag id string or a table with `id` and optional `duration`.

`id` must be a non-empty registered Tag id. Explicit `duration` is finite positive seconds; omission uses the Tag definition's default, or indefinite lifetime if neither supplies duration. Options permit only `id` and `duration`.

## ActionResourceRequirement {#action-resource-requirement}

Supported fields are numeric `min`, `max`, `minPercent`, and `maxPercent`; each is optional.

At least one threshold is required; all supplied thresholds must be finite and all comparisons are inclusive. Percent thresholds are in `[0, 1]`. Authored `min <= max` and `minPercent <= maxPercent` when each pair is supplied. Unsupported fields reject.

Percent thresholds compare `(current - resolvedMin) / (resolvedMax - resolvedMin)` and require a positive usable range. Absolute and percentage thresholds can coexist; every check must pass against pre-spend state.

## ActionResourceCost {#action-resource-cost}

Supply numeric `amount` or `percent`, with an optional string `multiplierProperty`.

Exactly one of `amount` or `percent` must be supplied, finite and strictly positive. Cost percentages may exceed `1`; percentage base cost is `(resolvedMax - resolvedMin) * percent`. A zero range is valid for costs. A positive numeric entry in `ActionDefinition.costs` is equivalent to `{ amount = value }`.

`multiplierProperty`, when supplied, must be a non-empty Property name. Its runtime resolved value must exist, be finite, and be non-negative; it multiplies the base cost. Effective cost must be finite/non-negative and affordable above the resolved minimum. Unknown fields reject; runtime failures are listed under [`RequestAction`](./action-controller#request-action).

## Callback aliases {#callbacks}

| Callback field | Signature |
| --- | --- |
| `onCanStart` | `(ctx: ActionStartContext) -> (boolean, string?)` |
| `onStart` | `(ctx: ActionExecutionContext) -> ()` |
| `onStopRequested` | `(ctx: ActionExecutionContext, request: ActionStopRequest) -> ()` |
| `onUpdate` | `(ctx: ActionExecutionContext, deltaTime: number) -> ()` |
| `onEnd` | `(ctx: ActionExecutionContext) -> ()` |
| `onInterrupt` | `(ctx: ActionExecutionContext, reason: string) -> ()` |
| `canBeInterruptedBy` | `(ctx: ActionExecutionContext, incoming: ActionInterruptionContext) -> boolean` |

`deltaTime` is finite positive elapsed seconds. `OnInterrupt` receives the interruption reason. `OnCanStart` can reject with a non-empty game-defined reason; `CanBeInterruptedBy` returns only a boolean and cannot expand the static allowlist.

Only `OnStart` may yield. Other hooks are non-yielding; stop/terminal failures are contained, update failure Interrupts with `ActionUpdateFailed`, and active start failure Interrupts with `ActionStartFailed`. See [hook behavior](/Action/action-lifecycle#hook-contracts) for lifetime and cancellation rules.

## ActionStartContext {#action-start-context}

| Field | Value |
| --- | --- |
| `actor` | The Actor performing the Action |
| `actionId` | The requested Action id string |
| `parameters` | Optional caller-supplied request data |

Frozen context passed to `onCanStart` before an activation exists. `parameters` is the original request value; there is no sequence id or lifecycle capability.

## ActionExecutionContext {#action-execution-context}

Includes the [start-context fields](#action-start-context), a numeric `sequenceId`, and the [`IsActive`, `End`, `Interrupt`, and `ClaimLocks` methods](./action-execution-context).

One frozen context per accepted activation, shared by its lifecycle/update callbacks and its owner-side interruption decision. Sequence id is a positive integer scoped to the Actor's controller. Original parameters are passed without copying; nested parameter data is not frozen by freezing the context.

Exact capability failures: [ActionExecutionContext API](./action-execution-context).

## ActionInterruptionContext {#action-interruption-context}

Contains `actor`, `actionId`, and optional `parameters`, describing the incoming Action.

Frozen incoming identity passed to an owner's `canBeInterruptedBy`. For a start it carries the incoming request parameters; for a scoped claim it carries the claimant's original start parameters. It has no sequence id or execution methods.

## ActionStopRequest {#action-stop-request}

Contains optional `parameters` of any type. Passed to `onStopRequested`; parameters are the original Stop-request value, distinct from `ctx.parameters`. KRF creates a new wrapper per delivery; this wrapper is not frozen.

## LockClaim {#lock-claim}

Frozen scoped-claim handle. [`Release`](./action-execution-context#release) is idempotent and safe after termination.

## ActionRequestResult {#action-request-result}

| `accepted` | Additional fields |
| --- | --- |
| `true` | `sequenceId`: the accepted activation's numeric id |
| `false` | `reason`: the rejection reason string |

Branch on `accepted` before reading the variant's fields. Acceptance identifies a committed activation, which may already be inactive when the request returns. Rejection creates no activation and consumes no sequence id. Exact rejection strings: [`RequestAction`](./action-controller#request-action).

## Lifecycle event payloads {#lifecycle-events}

Both payloads contain `actor` (Actor), `actionId` (string), and `sequenceId` (number). `ActionInterruptedEvent` also contains `reason` (string).

`OnActionStarted` and `OnActionEnded` carry `ActionLifecycleEvent`. `OnActionInterrupted` carries `ActionInterruptedEvent`. `reason` is a non-empty game-defined interruption reason or a runtime reason:

| Runtime reason | Cause |
| --- | --- |
| `ActionLockPreempted` | Approved lifetime/scoped lock preemption. |
| `ActionStartFailed` | `onStart` errors while the activation remains active. |
| `ActionUpdateFailed` | `onUpdate` errors or yields while still active. |
| `ActionControllerDestroyed` | Controller teardown. |

Payloads report the committed transition; current state may have changed through reentry. Grant changes use positional `(Actor, string, boolean)` arguments, not these payload types.

Related: [ActionRegistry](./action-registry), [ActionController](./action-controller), [ActionExecutionContext](./action-execution-context), [Actions Overview](/Action/actions-overview).
