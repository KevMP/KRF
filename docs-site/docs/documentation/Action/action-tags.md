---
sidebar_position: 5
---

# Action Tags

Actions use Tags both to gate starts and to publish effects. `TagController` still owns duplicate behavior, stacks, duration, ticking, and numeric Property modifiers.

## Choose a gate or an effect

| Field | Use | Lifetime |
| --- | --- | --- |
| `requiredTags` | Must be grounded or have a prerequisite status. | Presence checked at start; no automatic reaction to later loss. |
| `blockedTags` | Cannot start while stunned or silenced. | Absence checked at start; no automatic reaction to later application. |
| `activeTags` | Sprint speed, casting status, transformation modifiers. | Applied on acceptance; remaining contributions still owned by this activation are cleaned on termination. |
| `appliedTags` | A timed buff that survives completion or cancellation. | Applied on acceptance; follows ordinary Tag lifetime rules afterward. |

```lua
-- Fields inside an Action factory's returned definition.
requiredTags = { "Status.Grounded" },
blockedTags = { "Status.Stunned" },
activeTags = { "Status.Casting" },
appliedTags = { { id = "Buff.Courage", duration = 6 } },
```

Register every referenced Tag in `Server.Init({ tags = ..., actions = ... })`. An application can be a Tag id or `{ id = ..., duration = ... }`; omitted duration uses the Tag definition's default, and neither duration means indefinite. See [public types](/api/Action/action-types#action-tag-application) for exact validation.

## Apply effects declaratively

KRF applies `activeTags`, then `appliedTags`, each in declaration order. Acceptance and terminal cleanup commit Tags and derived Property/Resource state before consumer callbacks. You do not need to manually remove declarative active effects in `onEnd` or `onInterrupt`.

A required or blocked Tag is checked before the request factory and again after decision work. Preemption cannot bypass a failing gate: an Action blocked by another owner's Tag is rejected even if it could otherwise preempt that owner. See the [controller API](/api/Action/action-controller#request-action) for rejection strings and [advanced ordering](./action-ordering) for the full transaction.

Use a Tag's `properties` modifiers for temporary numeric effects. Game movement code reads the resolved `WalkSpeed` from `PropertyController`; Actions should not save and restore numeric base values to implement a temporary sprint buff. A Tag modifier does not create a custom Property: create its base value before relying on it.

## Active ownership follows ordinary Tag rules

| Tag behavior | Consequence for `activeTags` |
| --- | --- |
| `Stack` below its cap | Each new contribution can belong to its activation. Useful when activations can overlap. |
| `Ignore` with an existing instance | No new contribution is owned; termination preserves the existing Tag. |
| `Refresh` of an unrelated instance | Refreshing does not transfer cleanup ownership to the Action. |
| Expiry, consumption, replacement, or later external refresh | Cleanup does not remove replacement or externally refreshed state. |

An active Tag can expire before its Action ends. Repeated active declarations can refresh a record created by that same activation and retain ownership. If an `appliedTags` declaration refreshes that record, it relinquishes active cleanup ownership and survives termination under normal Tag rules. A later external refresh also protects it, including refresh at a stack cap.

For a status intended to last for exactly one exclusive activation, pair an indefinite active Tag with a lifetime lock and avoid unrelated systems refreshing it. For independent overlapping contributions, use `Stack` and choose its cap deliberately. `Ignore` and `Refresh` are not reference counting.

## React to later status changes

Start gates are not subscriptions. To cancel a channel when Grounded disappears, game code can listen to `OnTagRemoved` and `OnTagExpired`, check current `HasTag`, and call `ctx:Interrupt("LostGrounded")`. Check `ctx:IsActive()` before acting and disconnect in both terminal hooks. An earlier callback may already have reapplied the Tag, so a removal event alone does not prove current absence.

Use [Action Updates](./action-updates) when periodic checking better fits the behavior. Use [Tag Runtime](../Tags/tag-runtime) for duplicate rules and event distinctions, and [Action Patterns](./action-patterns#mode-transformation) for a temporary modifier example.

Next: [Action Resources](./action-resources).
