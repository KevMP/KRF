---
title: Presentation API
sidebar_label: API
---

# Presentation API

Register `{KRF.PresentationDefinition}` through `KRF.Client.Init({ presentations = definitions })`, and optional prediction policies through [`actionPredictionPolicies`](#actionpredictionpolicy) and [`hintPredictionPolicies`](#hintpredictionpolicy). Descriptors are frozen constants on `KRF.PresentationEvents` and `KRF.PresentationStates`. Each accepted entry gets one `PresentationContext`, which is the only runtime surface a definition uses. The [Presentation guide](./guide) shows how these pieces fit together.

## PresentationDefinition

| Field | Type | Contract |
| --- | --- | --- |
| `id` | `string` | Required unique nonempty definition ID |
| `entry` | `KRF.PresentationDefinitionEntry` | Required event or state binding |
| `predict` | `boolean?` | Optional. On `PresentationEvents.Action.Started`, `true` starts this definition early for the local player's own admitted Start, and the Action needs an [Action prediction policy](#actionpredictionpolicy). On `PresentationEvents.Hint.Received`, `true` lets a predicted cast start this definition early with [`ctx:PredictHint`](#predicthint), and the Hint needs a [Hint prediction policy](#hintpredictionpolicy). Not valid on any other entry. |
| `create` | `(ctx: KRF.PresentationContext) -> ()` | Required; runs once per accepted entry and may yield. The return value is ignored. |

`KRF.PresentationDefinitionEntry` is one of two bindings:

| Binding | Fields |
| --- | --- |
| `KRF.PresentationEntryBinding` | `event`: a [`PresentationEvents`](#presentationevents) descriptor, `id`: the exact nonempty source ID |
| `KRF.PresentationStateEntryBinding` | `state`: `PresentationStates.Tag.Active` or `PresentationStates.Action.Active`, `id`: the exact nonempty source ID |

The catalog is a dense array. An empty array and an omitted `presentations` field are both valid. Definitions and bindings reject unknown fields. Startup validates the whole catalog before it contacts the transport, copies each ID and binding, keeps the original `create` reference and never calls `create` during validation. Entries attach only after client startup succeeds. See [Startup failures](#startup-failures).

## PresentationEvents

Use these descriptors in `entry.event` and in [`ctx:On`](#on).

| Descriptor | Source signal | `id` selects |
| --- | --- | --- |
| `Action.Started` | `ActorView:GetActions().OnActionStarted` | Action ID |
| `Action.Ended` | `ActorView:GetActions().OnActionEnded` | Action ID |
| `Action.Interrupted` | `ActorView:GetActions().OnActionInterrupted` | Action ID |
| `Tag.Added` | `ActorView:GetTags().OnTagAdded` | Tag ID |
| `Tag.Refreshed` | `ActorView:GetTags().OnTagRefreshed` | Tag ID |
| `Tag.Removed` | `ActorView:GetTags().OnTagRemoved` | Tag ID |
| `Tag.Expired` | `ActorView:GetTags().OnTagExpired` | Tag ID |
| `Resource.Changed` | `ActorView:GetResources().OnResourceChanged` | Resource ID |
| `Hint.Received` | `HintRuntime.OnHintReceived` | Hint ID |

`Resource.Changed` starts an entry only when `change.source == "Commit"`. Baseline and recovery snapshots never replay Action or Tag occurrences.

### Entry event records

An event entry, and every `ctx:On` callback, receives one of these frozen records. Narrow by `source`.

| Type | `source` | `event` | Other fields |
| --- | --- | --- | --- |
| `KRF.ActionEntryEvent` | `"Action"` | `"Started"`, `"Ended"`, `"Interrupted"` | `actor: ActorView`, `action: ActionSnapshot` |
| `KRF.TagEntryEvent` | `"Tag"` | `"Added"`, `"Refreshed"`, `"Removed"`, `"Expired"` | `actor: ActorView`, `tagId: string` |
| `KRF.ResourceEntryEvent` | `"Resource"` | `"Changed"` | `actor: ActorView`, `change: ResourceViewChange` |
| `KRF.HintEntryEvent` | `"Hint"` | `"Received"` | `actor: ActorView?`, `hintId: string`, `payload: any?` |

`KRF.PresentationEntryEvent` is the union of the four. `ActionSnapshot`, `ResourceViewChange` and the Hint payload keep their [ActorView](../actors/client-views-api) and [Hint](../hints/api) contracts. A Hint record has `actor == nil` for a world Hint.

## PresentationStates

| Descriptor | Entry | Watch | Instance identity |
| --- | --- | --- | --- |
| `Tag.Active` | Yes | Yes, with a Tag ID | Definition, ActorView and Tag ID |
| `Action.Active` | Yes | Yes, for the instance's own activation | Definition, ActorView and activation `sequenceId` |
| `Resource.Current` | No | Yes, with a Resource ID | Not an entry |
| `Actor.Model` | No | Yes | Not an entry |
| `Action.LocalPrediction` | No | Yes, only on an instance with a predicted entry | Not an entry |

`KRF.PresentationStateDescriptor` is the union of all five, and `KRF.PresentationStateEntryDescriptor` is the two that can bind an entry. Using `Resource.Current`, `Actor.Model` or `Action.LocalPrediction` as an entry fails startup with `PresentationEntryStateInvalid`.

A `Tag.Active` instance exists while `ActorView:GetTags():GetTag(id)` returns a snapshot. An `Action.Active` instance exists while that activation is in `ActorView:GetActions():GetActiveActions()`. KRF retires the instance when its state is absent. After `Finish`, a `create` or callback error, or an [active-instance limit](#limits) refusal, the same occurrence does not start again until KRF observes it absent.

### State entry records

| Type | Fields |
| --- | --- |
| `KRF.TagStateEntry` | `source = "State"`, `kind = "Tag"`, `actor: ActorView`, `tagId: string`, `tag: ActiveTagSnapshot` |
| `KRF.ActionStateEntry` | `source = "State"`, `kind = "Action"`, `actor: ActorView`, `action: ActionSnapshot` |

`KRF.PresentationStateEntry` is the union of the two. `KRF.PresentationEntry`, the type of `ctx.entry`, is `PresentationEntryEvent | PresentationStateEntry | PredictedActionEntry | PredictedHintEntry`. Narrow by `source`, then by `kind`.

### Predicted entry record

| Type | Fields |
| --- | --- |
| `KRF.PredictedActionEntry` | `source = "ActionPrediction"`, `event = "RequestAdmitted"`, `actor: ActorView`, `actionId: string`, `originalStartKey: string`, `parameters: any?` |
| `KRF.PredictedHintEntry` | `source = "HintPrediction"`, `event = "Received"`, `actor: ActorView?`, `hintId: string`, `payload: any?` |

`actor` is the ActorView that made the request, and `originalStartKey` is the request's original Start key from `ClientActionRuntime.OnActionRequest`. `parameters` is decoded from the exact Start bytes that were sent, and each definition gets its own copy. The record has no `ActionSnapshot` and never changes. The server's `sequenceId` reaches the instance through `Watch(States.Action.LocalPrediction)` and the instance's Action listeners, not through `ctx.entry`.

A `PredictedHintEntry` comes from [`ctx:PredictHint`](#predicthint). `actor` is the target passed to it, or `nil` for an Actor-less Hint, and `payload` is a frozen shallow copy of the value passed. KRF does not check the payload against the Hint's schema, because the server's copy carries fields the client does not know yet. The instance shares its cast's local status: on a predicted hit with a target, `Watch(States.Action.LocalPrediction)` works, while `Watch(States.Action.Active)` and no-ID Action listeners do not, because it has no activation of its own. An Actor-less predicted hit has no ActorView, so every Watch on it raises `ActorMissing`.

## PresentationContext

| Member | Type / behavior |
| --- | --- |
| `entry` | `PresentationEntry`; the immutable entry record |
| `actor` | `ActorView?`; the original ActorView. A later view with the same Actor ID is a different origin. |
| `Own(cleanup)` | `(self, cleanup: () -> ()) -> ()`; registers a non-yielding cleanup. Registration after retirement runs the cleanup immediately. |
| `Finish()` | `(self) -> ()`; retires the instance once. The underlying gameplay is unaffected. |
| `IsActive()` | `(self) -> boolean`; true from acceptance until Finish, an authored failure, origin Actor retirement, runtime shutdown or, for a state entry, the state becoming absent |
| `On(event, [id or scope,] callback)` | `KRF.PresentationOn`; see [On](#on) |
| `Watch(state, [id,] callback)` | `KRF.PresentationWatch`; see [Watch](#watch) |
| `PredictHint(hintId, target?, payload?)` | `(self, string, ActorView?, any?) -> (boolean, string?)`; see [PredictHint](#predicthint) |

On retirement, KRF marks the context inactive and disconnects its subscriptions, then runs owned cleanups in reverse registration order. A failing or yielding cleanup is diagnosed and the remaining cleanups still run. Losing the Model alone never retires an instance.

### On {#on}

```lua
ctx:On(event: PresentationEventDescriptor, callback: (EntryEvent) -> ()) -> Connection
ctx:On(event: PresentationEventDescriptor, id: string, callback: (EntryEvent) -> ()) -> Connection
ctx:On(event: PresentationEventDescriptor, scope: { id: string, actor: ActorView }, callback: (EntryEvent) -> ()) -> Connection
ctx:On(Events.Hint.Received, scope: { id: string, scope: "Any" }, callback: (HintEntryEvent) -> ()) -> Connection
```

Each descriptor family takes its own callback type: `ActionEntryEvent`, `TagEntryEvent`, `ResourceEntryEvent` or `HintEntryEvent`.

| Form | Matches |
| --- | --- |
| No ID | The origin's own identity. Action listeners match the instance's activation. Tag, Resource and Hint listeners need an entry of the same family, and a Tag state entry counts as the Tag family. |
| `"ExactId"` | That source ID on the original ActorView. Action IDs match across activations. On an Actor-less Hint origin, matches Actor-less Hints. |
| `{ id, actor }` | That source ID on that ActorView. Another Actor never inherits the origin's activation. |
| `{ id, scope = "Any" }` | Hints only: that Hint ID with any Actor association, including Actor-less receipts |

Connections install synchronously and never replay earlier events. Callbacks run after the source publication returns, may yield, and are checked for connection and instance state immediately before they run. Cross-source order and completion order are not guaranteed. A callback error retires the instance. Resource follow-ups keep `change.source`, including `"Baseline"`. Retiring an explicitly scoped Actor disconnects only listeners scoped to it.

### Watch {#watch}

```lua
ctx:Watch(States.Tag.Active, tagId: string, callback: (ActiveTagSnapshot?) -> ()) -> Connection
ctx:Watch(States.Action.Active, callback: (ActionSnapshot?) -> ()) -> Connection
ctx:Watch(States.Resource.Current, resourceId: string, callback: (ResourceSnapshot?) -> ()) -> Connection
ctx:Watch(States.Actor.Model, callback: (Model?) -> ()) -> Connection
ctx:Watch(States.Action.LocalPrediction, callback: (LocalPredictionSnapshot) -> ()) -> Connection
```

| Form | Callback receives |
| --- | --- |
| `Tag.Active` | The Tag's snapshot on the original ActorView, or `nil` while it is absent |
| `Action.Active` | The instance's own activation, or `nil` once it is inactive. Requires an Action event, an Action state entry or a predicted Action entry. A predicted instance receives `nil` until its Start is accepted, and does not report the activation absent until the client has also seen that activation's replicated Start, so an accept that arrives first never reads as an end. If that Start is never seen, the wait ends when the Actor installs a replacement baseline, or 20 seconds after the request was sent. |
| `Resource.Current` | The Resource's snapshot on the original ActorView, or `nil` while it is absent |
| `Actor.Model` | The original ActorView's Model, or `nil` while unbound |
| `Action.LocalPrediction` | The instance's [local request status](#localpredictionsnapshot). Requires a predicted Action or Hint entry and is never `nil`. |

Watch subscribes first, then schedules one callback with the current value. Later callbacks follow meaningful changes. KRF samples again right before each callback and skips it when the value equals the last one delivered, so quick changes can collapse into one callback. Tag changes compare `stackCount` and expiry. Resource changes compare the stored replicated value, not the projected `current`, so regeneration and `remainingDuration` move without a callback. Callbacks may yield, and a newer callback can start while an older one is still running. A callback error retires the instance.

While the Actor is waiting for a replacement baseline, `Tag.Active`, `Action.Active` and `Resource.Current` callbacks pause and resume from the installed baseline. `Actor.Model` and `Action.LocalPrediction` keep delivering.

### PredictHint {#predicthint}

```lua
ctx:PredictHint(hintId: string, target: ActorView?, payload: any?) -> (boolean, string?)
```

Starts every `predict = true` definition for `hintId` now, on `target`, as if the server's Hint had arrived. Only an instance whose entry is a `PredictedActionEntry` can call it; a predicted hit cannot predict further hits. The call never sends anything to the server. Each predicted hit then waits for the server's matching Hint, the first one from the same activation for the same Hint ID and target. Predicted definitions skip that Hint, and definitions without `predict` still start from it.

| Result | Meaning |
| --- | --- |
| `true, nil` | At least one predicted definition started |
| `false, "InstanceInactive"` | The calling instance has finished |
| `false, "PredictionUnavailable"` | The calling instance's entry is not a `PredictedActionEntry` |
| `false, "PredictionExpired"` | The cast's prediction has ended: its reply horizon passed 20 seconds after the request, its Actor retired, or the runtime shut down |
| `false, "PredictionRejected"` | The server rejected the cast |
| `false, "HintNotPredicted"` | No definition for `hintId` sets `predict = true` |
| `false, "ActorUnavailable"` | `target` is not a current, available ActorView |
| `false, "HintAlreadyReceived"` | The server's Hint for this activation and target arrived within the last 3 seconds and played. Nothing starts. |
| `false, "PredictedHintLimit"` | The cast already has 16 predicted hits waiting |
| `false, "PredictionNotStarted"` | Every definition was refused, for example at the active-instance limit |

### LocalPredictionSnapshot

| Field | Type | Meaning |
| --- | --- | --- |
| `startStatus` | `"Admitted"`, `"Accepted"`, `"Rejected"` or `"Unknown"` | The original Start's outcome. `Unknown` means the reply did not arrive in time and can be followed by a late `Accepted` or `Rejected`. |
| `startReason` | `string?` | The reason given with a `Rejected` or `Unknown` Start |
| `sequenceId` | `number?` | The server activation, present only once the Start is `Accepted` |
| `inputTransitions` | `{ LocalPredictionInputDecision }` | The original press's local decisions in order, each with `transition`, `reason?` and `eventOrdinal`. At most 8 are kept. |
| `lastStop`, `lastInterrupt` | `LocalPredictionFollowUp?` | The latest Stop or Interrupt request for this Start, each with its own `requestKey`, `status` and `reason?` |

The snapshot is frozen and shared between definitions. The first callback includes every fact received before `create` ran. No status means the Action ended: an accepted Start does not prove the Action is still active, and an accepted Stop is not an end.

## ActionPredictionPolicy

`actionPredictionPolicies` maps a concrete Action ID to the checks the client can make for it. Every ID must be a request in `actionRequestSchemas`. A policy on its own predicts nothing until a definition sets `predict = true`.

| Field | Type | Contract |
| --- | --- | --- |
| `requiredTags` | `{ string }?` | Each Tag must be present on the original ActorView |
| `blockedTags` | `{ string }?` | No listed Tag may be present. A Tag may appear once, in only one list. |
| `resourceRequirements` | `{ [string]: ActionPredictionResourceRequirement }?` | `min`, `max`, `minPercent` and `maxPercent`, with the server's validation and inclusive bounds |
| `costs` | `{ [string]: number or ActionPredictionResourceCost }?` | A positive amount, or `{ amount }` or `{ percent }` with an optional `multiplierProperty`. Affordable when `current - min >= amount`. |
| `canPredictStart` | `((ActionPredictionCheckContext) -> boolean?)?` | Optional client-only check. Must not yield. |

`ActionPredictionCheckContext` is frozen and has `actor`, `actionId`, `originalStartKey` and `parameters`, the same values the [predicted entry](#predicted-entry-record) carries.

Startup copies every policy and never calls `canPredictStart` during validation. KRF evaluates each admitted Start once, after the request is sent, and the result applies to every predicted definition for that Action.

| Estimate | When | Effect |
| --- | --- | --- |
| Likely allowed | Every declared check passes and the callback, if any, returns `true` | Each predicted definition starts an instance now |
| Likely blocked | A declared Tag or Resource check fails, or the callback returns `false` | No early instance |
| Unknown | The ActorView is not ready, a declared Resource or the Tags domain is missing, a cost has a `multiplierProperty`, the sent bytes are unavailable, or the callback returns `nil`, errors, yields, returns a non-boolean or runs over 5 ms | No early instance |

A failed known check wins over an unknown one. Undeclared server checks, such as grants, locks and `onCanStart`, are never assumed to pass or fail. The request is sent whatever the estimate, and a Start that the client's request runtime refused locally is never predicted.

## HintPredictionPolicy

`hintPredictionPolicies` maps a Hint ID to the payload fields that say which activation caused it. A predicted Hint definition needs one for its Hint ID.

| Field | Type | Contract |
| --- | --- | --- |
| `actorIdField` | `string` | Payload field holding the Actor ID of the Actor whose Action caused the Hint, as `ActorView:GetId()` returns it |
| `sequenceIdField` | `string` | Payload field holding that Action activation's `sequenceId`. Must differ from `actorIdField`. |

The server fills both fields when it sends the Hint, usually from `ctx.actor:GetId()` and `ctx.sequenceId` in the Action's execution context. Startup copies the policy. It cannot check the fields against the server's Hint schema, because the Hint catalog arrives after the configuration is validated. A received Hint whose payload lacks a string `actorIdField` or a number `sequenceIdField` plays normally and is diagnosed with `PredictionHintSourceInvalid`.

When a server Hint arrives, KRF compares its activation with this client's predicted casts:

| Situation | Effect |
| --- | --- |
| A predicted hit waits for this activation, Hint ID and target | That hit is consumed. Predicted definitions skip the Hint, and the others start. |
| The activation is this client's accepted cast, with no predicted hit waiting | Every definition starts. KRF remembers the Hint for 3 seconds, so a later `PredictHint` for it returns `HintAlreadyReceived`. |
| The attacker is a cast of this client still waiting for its reply, with a predicted hit waiting | The predicted definitions' entry is held for at most 0.5 seconds. A matching reply consumes the hit. Anything else releases the Hint, and the visual can play twice. Retiring the attacker releases it too. |
| The attacker is a cast of this client still waiting for its reply, with no predicted hit waiting | Every definition starts. KRF remembers the Hint for 3 seconds, and the reply that proves it came from that cast makes a later `PredictHint` return `HintAlreadyReceived`. |
| Any other attacker or activation | Every definition starts normally |

### Connection

`On` and `Watch` return a [`KRF.Connection`](../getting-started/events) with idempotent `:Disconnect()`. The instance owns it, so you never pass it to `Own`. Finish, origin Actor retirement and runtime teardown disconnect every Connection. On an inactive context, both methods return an inert Connection without validating arguments.

## Limits

| Limit | Value | When exceeded |
| --- | --- | --- |
| Active instances per client | 256 | The entry is refused and diagnosed with `ActiveInstanceLimit`. A refused state occurrence is suppressed until absent. |
| Active subscriptions per instance | 64, shared by `On` and `Watch` | The call raises `SubscriptionLimit`. Existing subscriptions stay connected. Disconnecting frees a slot. |
| Tracked predicted Starts per client | 32 | The oldest idle record is dropped. If every record has a live instance, the Start is not predicted and is diagnosed with `PredictionAttemptLimit`. |
| Held authoritative Starts per client | 32, each for at most 0.5 seconds | Further ambiguous Starts start immediately and are diagnosed with `PredictionDeferredLimit` |
| Correlation record for a predicted Start | Until its replicated Start is matched or the Start is rejected, and at most 20 seconds after the request was sent | After 20 seconds the Start no longer holds back other Starts. Once its instances finish, the record is dropped and a later replicated Start of that activation starts normally. |
| Input decisions per predicted Start | 8 | Later decisions are dropped and diagnosed with `PredictionTransitionLimit` |
| Predicted hits waiting per predicted Start | 16 | `PredictHint` returns `false, "PredictedHintLimit"` |
| Wait for a predicted hit's server Hint | 3 seconds | The hit stops waiting, and a later matching Hint plays normally |
| Remembered server Hints per predicted Start | 8, each for 3 seconds | Further Hints still play but are not remembered for `HintAlreadyReceived` |
| Remembered server Hints that arrive before their cast's reply | 8 per attacking Actor, each for 3 seconds | Further Hints still play but are not remembered |

## Misuse errors

A malformed `On`, `Watch` or `PredictHint` call raises an error at the caller, formatted as `[Presentation] id=<definition> On: <Reason>: <detail>`, `... Watch: ...` or `... PredictHint: ...`. `On` and `Watch` check their arguments only on an active context. A misuse never subscribes, never starts an instance and never widens to all Actors.

| Reason | Method | Cause |
| --- | --- | --- |
| `UnknownEventDescriptor` | On | The descriptor is not a `PresentationEvents` constant |
| `UnknownStateDescriptor` | Watch | The descriptor is not a `PresentationStates` constant |
| `InvalidArguments` | Both | Wrong argument count or shape for the descriptor |
| `CallbackInvalid` | Both | The callback is not a function |
| `IdInvalid` | All | The ID or Hint ID is empty or not a string |
| `TargetInvalid` | PredictHint | `target` is neither `nil` nor an ActorView |
| `FilterInvalid`, `ScopeFieldUnknown`, `ScopeInvalid` | On | The scope record is malformed, has extra fields or names no usable ActorView |
| `OriginIdMissing` | On | A no-ID listener whose origin is a different source family |
| `OriginActionMissing` | Both | A no-ID Action listener or Action Watch without an origin activation |
| `OriginPredictionMissing` | Watch | `Action.LocalPrediction` on an instance without a predicted entry |
| `ActorMissing` | Both | No ActorView to scope to, including Watch on an Actor-less Hint instance |
| `ActorUnavailable` | Both | The scoped ActorView is no longer current and available |
| `SubscriptionLimit` | Both | The instance already has 64 active subscriptions |

## Runtime diagnostics

Authored failures retire only the affected instance and warn with `[Presentation] id=<definition> source=<source> event=<event> actor=<id> reason=<reason>`. State entries report `event` as `Tag.Active` or `Action.Active`.

| Reason | Cause |
| --- | --- |
| `CreateFailed:<message>` | `create` raised an error |
| `CallbackFailed:<message>` | An `On` callback raised an error |
| `WatchFailed:<message>` | A `Watch` callback raised an error |
| `CleanupFailed:<message>` | An owned cleanup raised an error or yielded |
| `ActiveInstanceLimit` | The entry was refused at the active-instance limit |

A non-string error value appears as `NonStringError`.

Prediction warns with `[Presentation] action=<id> actor=<id> reason=<reason>`. None of these affect the request.

| Reason | Cause |
| --- | --- |
| `PredictionParametersUnavailable`, `PredictionParametersInvalid` | The sent Start bytes were missing or could not be decoded |
| `PredictionCallbackFailed:<message>`, `PredictionCallbackYielded`, `PredictionCallbackReturnInvalid`, `PredictionCallbackOverBudget` | `canPredictStart` failed, so the estimate is unknown |
| `PredictionAttemptLimit`, `PredictionDeferredLimit`, `PredictionTransitionLimit` | A [prediction limit](#limits) was reached |

Predicted hits warn with `[Presentation] hint=<id> reason=<reason>`.

| Reason | Cause |
| --- | --- |
| `PredictionHintSourceInvalid` | A received Hint's payload lacks the fields its [Hint prediction policy](#hintpredictionpolicy) names. It plays normally. |
| `PredictionDeferredLimit` | The held-entry limit was reached, so an ambiguous Hint started immediately |

## Startup failures

`KRF.Client.Init` reports these under `system = "Presentation"`:

| Reason | Cause |
| --- | --- |
| `PresentationCatalogInvalid` | `presentations` is not a dense array |
| `PresentationDefinitionInvalid` | A member is not a plain table |
| `PresentationDefinitionFieldUnknown` | A definition has a field other than `id`, `entry`, `predict` and `create` |
| `PresentationIdInvalid`, `PresentationIdDuplicate` | Empty, non-string or repeated definition ID |
| `PresentationCreateInvalid` | `create` is not a function |
| `PresentationEntryInvalid` | `entry` is not a plain table |
| `PresentationEntryFieldUnknown` | The binding has a field other than `event`, `state` and `id` |
| `PresentationEntryAmbiguous` | The binding has both `event` and `state` |
| `PresentationEntryEventInvalid` | No `state`, and `event` is not a `PresentationEvents` constant |
| `PresentationEntryStateInvalid` | `state` is not `Tag.Active` or `Action.Active` |
| `PresentationEntryIdInvalid` | The source ID is empty or not a string |
| `PresentationPredictInvalid` | `predict` is not a boolean |
| `PresentationPredictEntryInvalid` | `predict = true` on an entry other than `PresentationEvents.Action.Started` or `PresentationEvents.Hint.Received` |
| `PresentationPredictionPolicyMissing` | `predict = true` without an Action prediction policy for that Action ID, or without a Hint prediction policy for that Hint ID |
| `ActionPredictionPoliciesInvalid` | `actionPredictionPolicies` is not a plain table |
| `ActionPredictionPolicyIdInvalid`, `ActionPredictionPolicyActionUnknown` | An empty or non-string key, or an Action missing from `actionRequestSchemas` |
| `ActionPredictionPolicyInvalid`, `ActionPredictionPolicyFieldUnknown`, `ActionPredictionPolicyCallbackInvalid` | A policy is not a plain table, has an unknown field, or `canPredictStart` is not a function |
| `ActionPredictionPolicyTagsInvalid`, `ActionPredictionPolicyTagDuplicate` | A Tag list is not a dense array of nonempty strings, or a Tag repeats |
| `ActionPredictionPolicyRequirementsInvalid`, `ActionPredictionPolicyRequirementInvalid` | A Resource requirement is malformed |
| `ActionPredictionPolicyCostsInvalid`, `ActionPredictionPolicyCostInvalid` | A cost is malformed |
| `HintPredictionPoliciesInvalid`, `HintPredictionPolicyIdInvalid` | `hintPredictionPolicies` is not a plain table, or a key is empty or not a string |
| `HintPredictionPolicyInvalid`, `HintPredictionPolicyFieldUnknown` | A policy is not a plain table or has a field other than `actorIdField` and `sequenceIdField` |
| `HintPredictionPolicySourceInvalid` | `actorIdField` or `sequenceIdField` is missing or empty, or both name the same field |
| `PresentationInstallationFailed` | Presentation could not attach its source listeners |

See the [initialization API](../getting-started/initialization-api#clientinit) for the rest of `Client.Init`.
