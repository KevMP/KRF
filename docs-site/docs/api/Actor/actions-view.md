# ActionsView

`ActionsView` is one Actor's read-only client view of active visible Action instances and their lifecycle occurrences.

```lua
local actions = actorView:GetActions()
-- Public contracts: KRF.client.Actor.types.ActionsView and ActionSnapshot.
```

## Members

| Kind | Signature |
| --- | --- |
| Method | [`IsActionActive(actionId: string) -> boolean`](#active) |
| Method | [`GetAction(sequenceId: number) -> ActionSnapshot?`](#action) |
| Method | [`GetActiveActions() -> { ActionSnapshot }`](#actions) |
| Event | [`OnActionStarted: Event<ActionSnapshot>`](#started) |
| Event | [`OnActionEnded: Event<ActionSnapshot>`](#ended) |
| Event | [`OnActionInterrupted: Event<ActionSnapshot>`](#interrupted) |
| Event | [`OnStateChanged: Event<DomainChangeSource>`](#changed) |

## Methods

### `IsActionActive(actionId: string) -> boolean` {#active}

Returns whether at least one current visible instance has this Action id. Unknown, private and retired entries return `false`.

### `GetAction(sequenceId: number) -> ActionSnapshot?` {#action}

Returns an immutable identity snapshot for this active visible sequence, or `nil` when absent or retired.

| Snapshot field | Meaning |
| --- | --- |
| `actionId: string` | Semantic visible Action id |
| `sequenceId: number` | Activation identity within this Actor's ActionController lifetime; positive integer through 4,294,967,295 |

Snapshots contain only these fields. Retained snapshots remain historical identity after termination.

### `GetActiveActions() -> { ActionSnapshot }` {#actions}

Returns an immutable array of immutable active snapshots ordered by ascending sequence id. Concurrent instances with the same Action id remain separate entries. Empty and retired views return an empty array.

## Events

### `OnActionStarted: Event<ActionSnapshot>` {#started}

Reports a live visible activation after that commit's complete Actor state installs.

### `OnActionEnded: Event<ActionSnapshot>` {#ended}

Reports a live normal completion after the instance leaves current state.

### `OnActionInterrupted: Event<ActionSnapshot>` {#interrupted}

Reports a live interruption after the instance leaves current state. The payload excludes the server interruption reason.

All three events carry immutable identity. Initial and replacement baselines replay no lifecycle events. A scheduled or yielding listener can observe newer current state; see the [ActionsView guide](/Action/action-views#history).

### `OnStateChanged: Event<DomainChangeSource>` {#changed}

Reports differing current Action state with `"Commit"` for a live change or `"Baseline"` for replacement reconciliation. Initial binding and equal replacement truth emit no change. Subscriptions and facade identity survive replacement baselines and Model streaming; Actor removal retires them.

## Related

- [ActionsView guide](/Action/action-views)
- [ActorView](./actor-view)
- [ActorView Registry](./actor-view-registry)
