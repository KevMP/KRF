---
sidebar_position: 1
---

# Property Controller

`PropertyController` is the per-actor runtime API for numeric properties.

Game code usually gets it from an actor:

```lua
local propertyController = actor:GetController("PropertyController")
```

## Methods

### `SetBaseProperty(propertyName, value) -> (boolean, string?)`

Sets the base value for a property.

If the property does not exist yet, this creates it.

Returns:

* `true, nil` on success
* `false, "InvalidPropertyValue"` if `value` is not numeric

### `GetBaseProperty(propertyName) -> number?`

Returns the current base value for a property.

### `GetResolvedProperty(propertyName) -> number?`

Returns the current resolved value for a property.

### `GetResolvedProperties() -> {[string]: number}`

Returns every resolved property currently stored on the actor.

### `HasProperty(propertyName) -> boolean`

Reports whether the actor currently has that property entry.

### `Destroy() -> ()`

Destroys the controller and its owned signals.

## Events

### `OnBasePropertyChanged`

Fires when a base property value changes.

```lua
SignalTypes.Event<Actor, string, number?, number>
```

### `OnResolvedPropertyChanged`

Fires when a resolved property value changes.

```lua
SignalTypes.Event<Actor, string, number?, number>
```

### `OnPropertyChanged`

Fires a structured property change record.

```lua
type PropertyChange = {
	actor: Actor,
	propertyName: string,
	oldBaseValue: number?,
	newBaseValue: number,
	oldResolvedValue: number?,
	newResolvedValue: number,
}
```

## Built-in Defaults

Every new controller starts with:

* `WalkSpeed = 16`
* `JumpPower = 50`

## Related

* [Property Runtime concepts](/Property/property-runtime)
* [Tag Registry](../Tags/tag-registry)
* [Tag Controller](../Tags/tag-controller)
