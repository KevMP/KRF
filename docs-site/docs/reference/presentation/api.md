---
title: Presentation API
sidebar_label: API
---

# Presentation API

Register `{KRF.PresentationDefinition}` through `KRF.Client.Init({ presentations = definitions })`. Descriptors are frozen constants on `KRF.PresentationEvents` and `KRF.PresentationStates`. Each accepted entry gets one `PresentationContext`, which is the only runtime surface a definition uses. The [Presentation guide](./guide) shows how these pieces fit together.

## PresentationDefinition

| Field | Type | Contract |
| --- | --- | --- |
| `id` | `string` | Required unique nonempty definition ID |
| `entry` | `KRF.PresentationDefinitionEntry` | Required event or state binding |
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

`KRF.PresentationStateDescriptor` is the union of all four, and `KRF.PresentationStateEntryDescriptor` is the two that can bind an entry. Using `Resource.Current` or `Actor.Model` as an entry fails startup with `PresentationEntryStateInvalid`.

A `Tag.Active` instance exists while `ActorView:GetTags():GetTag(id)` returns a snapshot. An `Action.Active` instance exists while that activation is in `ActorView:GetActions():GetActiveActions()`. KRF retires the instance when its state is absent. After `Finish`, a `create` or callback error, or an [active-instance limit](#limits) refusal, the same occurrence does not start again until KRF observes it absent.

### State entry records

| Type | Fields |
| --- | --- |
| `KRF.TagStateEntry` | `source = "State"`, `kind = "Tag"`, `actor: ActorView`, `tagId: string`, `tag: ActiveTagSnapshot` |
| `KRF.ActionStateEntry` | `source = "State"`, `kind = "Action"`, `actor: ActorView`, `action: ActionSnapshot` |

`KRF.PresentationStateEntry` is the union of the two. `KRF.PresentationEntry`, the type of `ctx.entry`, is `PresentationEntryEvent | PresentationStateEntry`. Narrow by `source`, then by `kind`.

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
```

| Form | Callback receives |
| --- | --- |
| `Tag.Active` | The Tag's snapshot on the original ActorView, or `nil` while it is absent |
| `Action.Active` | The instance's own activation, or `nil` once it is inactive. Requires an Action event or Action state entry. |
| `Resource.Current` | The Resource's snapshot on the original ActorView, or `nil` while it is absent |
| `Actor.Model` | The original ActorView's Model, or `nil` while unbound |

Watch subscribes first, then schedules one callback with the current value. Later callbacks follow meaningful changes. KRF samples again right before each callback and skips it when the value equals the last one delivered, so quick changes can collapse into one callback. Tag changes compare `stackCount` and expiry. Resource changes compare the stored replicated value, not the projected `current`, so regeneration and `remainingDuration` move without a callback. Callbacks may yield, and a newer callback can start while an older one is still running. A callback error retires the instance.

While the Actor is waiting for a replacement baseline, `Tag.Active`, `Action.Active` and `Resource.Current` callbacks pause and resume from the installed baseline. `Actor.Model` keeps delivering.

### Connection

`On` and `Watch` return a [`KRF.Connection`](../getting-started/events) with idempotent `:Disconnect()`. The instance owns it, so you never pass it to `Own`. Finish, origin Actor retirement and runtime teardown disconnect every Connection. On an inactive context, both methods return an inert Connection without validating arguments.

## Limits

| Limit | Value | When exceeded |
| --- | --- | --- |
| Active instances per client | 256 | The entry is refused and diagnosed with `ActiveInstanceLimit`. A refused state occurrence is suppressed until absent. |
| Active subscriptions per instance | 64, shared by `On` and `Watch` | The call raises `SubscriptionLimit`. Existing subscriptions stay connected. Disconnecting frees a slot. |

## Misuse errors

A malformed `On` or `Watch` call on an active context raises an error at the caller, formatted as `[Presentation] id=<definition> On: <Reason>: <detail>` or `... Watch: ...`. A misuse never subscribes and never widens to all Actors.

| Reason | Method | Cause |
| --- | --- | --- |
| `UnknownEventDescriptor` | On | The descriptor is not a `PresentationEvents` constant |
| `UnknownStateDescriptor` | Watch | The descriptor is not a `PresentationStates` constant |
| `InvalidArguments` | Both | Wrong argument count or shape for the descriptor |
| `CallbackInvalid` | Both | The callback is not a function |
| `IdInvalid` | Both | The ID is empty or not a string |
| `FilterInvalid`, `ScopeFieldUnknown`, `ScopeInvalid` | On | The scope record is malformed, has extra fields or names no usable ActorView |
| `OriginIdMissing` | On | A no-ID listener whose origin is a different source family |
| `OriginActionMissing` | Both | A no-ID Action listener or Action Watch without an origin activation |
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

## Startup failures

`KRF.Client.Init` reports these under `system = "Presentation"`:

| Reason | Cause |
| --- | --- |
| `PresentationCatalogInvalid` | `presentations` is not a dense array |
| `PresentationDefinitionInvalid` | A member is not a plain table |
| `PresentationDefinitionFieldUnknown` | A definition has a field other than `id`, `entry` and `create` |
| `PresentationIdInvalid`, `PresentationIdDuplicate` | Empty, non-string or repeated definition ID |
| `PresentationCreateInvalid` | `create` is not a function |
| `PresentationEntryInvalid` | `entry` is not a plain table |
| `PresentationEntryFieldUnknown` | The binding has a field other than `event`, `state` and `id` |
| `PresentationEntryAmbiguous` | The binding has both `event` and `state` |
| `PresentationEntryEventInvalid` | No `state`, and `event` is not a `PresentationEvents` constant |
| `PresentationEntryStateInvalid` | `state` is not `Tag.Active` or `Action.Active` |
| `PresentationEntryIdInvalid` | The source ID is empty or not a string |
| `PresentationInstallationFailed` | Presentation could not attach its source listeners |

See the [initialization API](../getting-started/initialization-api#clientinit) for the rest of `Client.Init`.
