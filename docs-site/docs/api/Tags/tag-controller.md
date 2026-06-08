---
sidebar_position: 2
---

# Tag Controller

`TagController` is the per-actor runtime API for applying, removing, and querying active tags.

Game code usually gets it from an actor:

```lua
local tagController = actor:GetController("TagController")
```

## Methods

### `AddTag(tagId, options?) -> (boolean, string?)`

Applies one active tag instance to the actor.

Returns:

* `true, nil` on success
* `false, "UnknownTagId:<tagId>"` if the tag is not registered
* `false, "TagDurationMustBePositive"` if `options.duration` is `<= 0`
* `false, "TagActiveInstancesInitFailed:<tagId>"` if runtime state cannot initialize

Reapplying a tag follows the definition's `duplicateBehavior`.

### `RemoveTag(tagId) -> (boolean, string?)`

Removes every active instance for that tag id.

Returns `false, "TagNotActive"` if the actor does not currently have that tag.

### `RemoveSingleTag(tagId) -> (boolean, string?)`

Removes exactly one active instance for that tag id.

For stacked tags, KRF removes the oldest applied instance first.

Returns `false, "TagNotActive"` if the actor does not currently have that tag.

### `HasTag(tagId) -> boolean`

Reports whether the actor currently has at least one active instance for that tag id.

### `GetActiveTags() -> {ActiveTagSnapshot}`

Returns one summary record per active tag id.

```lua
type ActiveTagSnapshot = {
	tagId: string,
	stackCount: number,
	remainingDuration: number?,
}
```

For timed stacks, `remainingDuration` is the longest remaining duration still active for that tag id.

### `GetTagInstances(tagId) -> {TagInstanceSnapshot}`

Returns per-instance records for one active tag id.

```lua
type TagInstanceSnapshot = {
	tagId: string,
	duration: number?,
	remainingDuration: number?,
	appliedOrder: number,
}
```

Returns an empty array when the tag is not active.

### `Destroy() -> ()`

Destroys the controller and disconnects its owned signals.

## Events

### `OnTagAdded`

Fires when a tag becomes active on the actor.

```lua
SignalTypes.Event<Actor, string>
```

### `OnTagRemoved`

Fires when one or more active instances are removed manually.

```lua
SignalTypes.Event<Actor, string>
```

### `OnTagRefreshed`

Fires when an active instance is refreshed instead of a new one being added.

```lua
SignalTypes.Event<Actor, string>
```

### `OnTagChanged`

Fires after any successful add, refresh, removal, or expiry.

```lua
SignalTypes.Event<Actor, string>
```

### `OnTagExpired`

Fires when a timed tag instance expires because its remaining duration reached zero.

```lua
SignalTypes.Event<Actor, string>
```

## Key Types

```lua
type AddTagOptions = {
	duration: number?,
}
```

## Notes

`TagController` owns active tag state on one actor. `TagRegistry` still owns the shared tag catalog and validation rules.

## Related

* [Tag Registry](./tag-registry)
* [Tag Runtime concepts](/Tags/tag-runtime)
* [Actor](/api/Actor/)
