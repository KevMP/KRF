---
sidebar_position: 2
---

# Action Controller

`ActionController` is KRF's per-Actor Action runtime. The members below provide its grant surface; obtain the controller after the Actor is registered.

```lua
local actions = actor:GetController("ActionController")
```

## Members

| Kind | Signature |
| --- | --- |
| Method | [`SetGrants(sourceId: string, actionIds: {string}) -> (boolean, string?)`](#set-grants) |
| Method | [`IsActionGranted(actionId: string) -> boolean`](#is-action-granted) |
| Method | [`GetGrantedActions() -> {string}`](#get-granted-actions) |
| Method | [`Destroy() -> ()`](#destroy) |
| Event | [`OnActionGrantChanged: Event<Actor, string, boolean>`](#on-action-grant-changed) |

## Methods

### `SetGrants(sourceId: string, actionIds: {string}) -> (boolean, string?)` {#set-grants}

Atomically replaces one source's complete Action set. Returns `true, nil` on success, including an unchanged set or an empty-set clear.

| Failure reason | Cause |
| --- | --- |
| `ActionGrantSourceIdMustBeString` | The source id is not a string. |
| `ActionGrantSourceIdCannotBeEmpty` | The source id is empty. |
| `ActionGrantIdsMustBeTable` | The Action ids are not a table. |
| `ActionGrantIdsMustBeArray` | The table is not a dense array. |
| `ActionGrantIdMustBeString` | An entry is not a string. |
| `ActionGrantIdCannotBeEmpty` | An entry is empty. |
| `UnknownActionId:<id>` | An Action id is absent from the loaded registry. |
| `ActionControllerDestroyed` | The controller has been destroyed. |

Failure leaves all source and effective grants unchanged.

### `IsActionGranted(actionId: string) -> boolean` {#is-action-granted}

Returns whether the Action is effectively granted to this Actor; an unknown id returns `false`.

### `GetGrantedActions() -> {string}` {#get-granted-actions}

Returns a frozen list of effective Action ids in Action catalog order.

### `Destroy() -> ()` {#destroy}

Clears runtime grants and destroys the owned event. Repeated calls are safe.

## Events

### `OnActionGrantChanged: Event<Actor, string, boolean>` {#on-action-grant-changed}

Fires when this Actor's effective grant for one Action changes. Arguments are the Actor, Action id, and new granted state.

## Related

- [Action grants guide](/Action/action-grants)
- [Action Registry](/api/Action/action-registry)
