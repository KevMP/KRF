---
title: Tags API
---

# Tags API

## TagDefinition

| Field | Type | Contract |
| --- | --- | --- |
| `id` | `string` | Required unique non-empty ID |
| `duplicateBehavior` | `"Ignore" \| "Refresh" \| "Stack"` | Required |
| `visibility` | `"ServerOnly" \| "ClientVisible"` | Required; visible entries reach every client |
| `defaultDuration` | `number?` | Positive duration in seconds; absent means indefinite |
| `tickInterval` | `number?` | Positive interval in seconds; required for tick scheduling |
| `onTick` | `((actor: Actor, deltaTime: number) -> ())?` | Synchronous server callback; see the current timing contract below |
| `maxStacks` | `number?` | Positive integer; allowed only with Stack |
| `properties` | `{ [string]: PropertyModifier }?` | Modifiers for registered Properties |

Register the catalog with `Server.Init({ tags = definitions })`. Startup owns immutable copies of definitions and their modifiers. Unknown top-level definition fields are currently ignored; unknown modifier fields reject validation.

A callback without `tickInterval` isn't scheduled. Treat the two fields as a pair when authoring a ticking effect. The current validator validates them individually; it doesn't enforce a required pair. Supply finite numeric values: duration, interval and modifier validation does not perform a general finiteness check.

### Property modifiers {#property-modifiers}

`PropertyModifier` permits `set`, `add`, `multiply`, `min` and `max`, each numeric and optional. At least one field is required. `set` cannot appear with another modifier field. Unsupported modifier fields reject the definition. Resolution order and stack contributions are in [Properties](../properties/guide).

### Tick callback

```lua
onTick: ((actor: KRF.Actor, deltaTime: number) -> ())?
```

The current delta is the advancement step that made this instance due, normally `0.1` under automatic advancement. It is not the sum of intervening steps. Refresh preserves the tick countdown. At most one tick is dispatched per instance per pass, and overflow is discarded when the countdown resets. See [#145](https://github.com/KevMP/KRF/issues/145) for the proposed elapsed-time correction.

Callbacks run inline under `pcall`. Throwing warns and lets the pass continue. KRF does not reject or cancel a yielding tick callback; it can suspend later ticks and expiry work in that pass. Keep callbacks non-yielding.

## TagController

```lua
local tags = actor:GetController("TagController") :: KRF.TagController
```

### Mutations

| Signature | Behavior |
| --- | --- |
| `tags:AddTag(tagId: string, options: AddTagOptions?) -> (boolean, string?)` | Applies the registered definition according to its duplicate policy |
| `tags:RemoveTag(tagId: string) -> (boolean, string?)` | Removes all active instances of the ID |
| `tags:RemoveSingleTag(tagId: string) -> (boolean, string?)` | Removes the oldest applied active instance |

`AddTagOptions` contains optional `duration: number`. Supply a positive finite override; nil uses the definition's default rather than clearing it. Successful mutation returns `true, nil`; an ignored duplicate also succeeds but emits nothing. Direct AddTag currently checks only whether an override is non-positive, so malformed option types may throw instead of returning a validation reason.

| Failure | Applies to / cause |
| --- | --- |
| `TagControllerDestroyed` | AddTag after teardown |
| `UnknownTagId:<id>` | Add for an unregistered ID |
| `TagDurationMustBePositive` | Non-positive duration override |
| `TagNotActive` | Removal with no active instance, including after teardown |
| `TagActiveInstancesInitFailed:<id>` | Instance storage could not be initialized |

### Queries

| Signature | Return |
| --- | --- |
| `tags:HasTag(tagId: string) -> boolean` | Active presence |
| `tags:GetActiveTags() -> { ActiveTagSnapshot }` | Aggregate rows ordered by oldest active application |
| `tags:GetTagInstances(tagId: string) -> { TagInstanceSnapshot }` | Per-instance snapshots, or empty when inactive |

Aggregate rows contain `tagId: string`, `stackCount: number` and `remainingDuration: number?`. The current server aggregate reports the longest remaining duration among timed instances; indefinite instances do not contribute a duration. It is nil when no timed instance remains. Use instance rows to distinguish mixed timed and indefinite stacks.

Instance rows contain `tagId: string`, `duration: number?`, `remainingDuration: number?` and `appliedOrder: number`. Duration is the value from creation or the most recent refresh; appliedOrder retains the original creation order. Instance enumeration retains that application order.

Server queries return fresh mutable snapshot tables; editing one doesn't mutate the Controller, and retaining one doesn't make its countdown update. Server instance detail isn't replicated through TagsView, whose snapshots are frozen.

### Events

Each event carries `(actor: KRF.Actor, tagId: string)`.

| Operation | Events |
| --- | --- |
| New instance | `OnTagAdded`, then `OnTagChanged` |
| Refresh, including refresh at a stack cap | `OnTagRefreshed`, then `OnTagChanged` |
| Manual removal | `OnTagRemoved`, then `OnTagChanged` |
| Timed expiry | `OnTagExpired`, then `OnTagChanged` |
| Ignored duplicate or tick-only work | None |

Events fire once per mutation, not just when presence changes from absent to present or back. Removing all stacks with RemoveTag emits one Removed/Changed pair; expiry of several individual stacks can emit several Expired/Changed pairs. Manual removal doesn't emit Expired. A tick that removes or refreshes its own instance is respected by the later expiry phase.

For each mutation, affected Properties and dependent Resource configuration are installed before public Tag notifications. Reentrant listeners can cause newer mutations, so query current state rather than assuming the event's Tag ID is now absent. A derived-state/publication failure can propagate after authority changed; the mutation is not rolled back.

`tags:Destroy() -> ()` is idempotent and removes state and subscriptions without emitting removal or expiry events. ActorRuntime owns this call during normal teardown. Queries then return false or empty snapshots.

## TagRegistry

| Signature | Return |
| --- | --- |
| `KRF.TagRegistry.Get(id: string) -> TagDefinition?` | Loaded definition or `nil` |
| `KRF.TagRegistry.GetAll() -> { TagDefinition }` | Frozen array in catalog order |
| `KRF.TagRegistry.GetAllById() -> { [string]: TagDefinition }` | Frozen definition lookup map |
| `KRF.TagRegistry.IsLoaded() -> boolean` | Installation state |

Use `Server.Init({ tags = ... })` to load definitions. `Load` is startup infrastructure.

### Definition failure families

| Reason / family | Invalid input |
| --- | --- |
| `TagDefinitionMissing`, `TagDefinitionMustBeTable` | Missing or malformed entry |
| `TagIdMissing`, `TagIdMustBeString`, `TagIdCannotBeEmpty`, `TagIdAlreadyRegistered` | ID or uniqueness |
| `TagDefaultDurationMustBeNumber`, `TagDefaultDurationMustBePositive` | Default duration |
| `TagTickIntervalMustBeNumber`, `TagTickIntervalMustBePositive` | Tick interval |
| `TagDuplicateBehaviorMissing`, `TagDuplicateBehaviorMustBeString`, `TagDuplicateBehaviorInvalid` | Duplicate policy |
| `TagVisibilityMissing`, `TagVisibilityMustBeString`, `TagVisibilityInvalid` | Visibility |
| `TagMaxStacksMustBeNumber`, `TagMaxStacksMustBePositive`, `TagMaxStacksMustBeInteger`, `TagMaxStacksRequiresStackDuplicateBehavior` | Stack limit |
| `TagOnTickMustBeFunction` | Callback |
| `TagPropertiesMustBeTable`, `TagPropertyNameMustBeString`, `TagPropertyNameCannotBeEmpty` | Property map |
| `TagPropertyModifierMustBeTable`, `TagPropertyModifierFieldInvalid`, `TagPropertyModifierValueMustBeNumber`, `TagPropertyModifierCannotBeEmpty`, `TagPropertyModifierSetCannotBeCombined` | Modifier |
| `PropertyDefinitionsNotLoaded`, `UnknownPropertyId:<id>` | Referenced Property |

See [Tags](./guide) and [client TagsView](../actors/client-views-api#tagsview).
