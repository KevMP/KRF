---
sidebar_position: 1
---

# Property Controller

`PropertyController` owns numeric base and resolved values for one Actor. Obtain it from the Actor after controller attachment.

```lua
local properties = actor:GetController("PropertyController")
```

## Members

| Kind | Signature |
| --- | --- |
| Method | [`SetBaseProperty(propertyName: string, value: number) -> (boolean, string?)`](#set-base-property) |
| Method | [`GetBaseProperty(propertyName: string) -> number?`](#get-base-property) |
| Method | [`GetResolvedProperty(propertyName: string) -> number?`](#get-resolved-property) |
| Method | [`GetResolvedProperties() -> {[string]: number}`](#get-resolved-properties) |
| Method | [`HasProperty(propertyName: string) -> boolean`](#has-property) |
| Method | [`Destroy() -> ()`](#destroy) |
| Event | [`OnBasePropertyChanged: Event<Actor, string, number?, number>`](#on-base-property-changed) |
| Event | [`OnResolvedPropertyChanged: Event<Actor, string, number?, number>`](#on-resolved-property-changed) |
| Event | [`OnPropertyChanged: Event<PropertyChange>`](#on-property-changed) |

## Methods

### `SetBaseProperty(propertyName: string, value: number) -> (boolean, string?)` {#set-base-property}

Creates or updates a numeric base value, then recomputes the resolved value from active tags.

**Returns**

- `true, nil`: the value is valid. Writing the current base value is a successful no-op.
- `false, "InvalidPropertyValue"`: `value` is not a number; no property is created or changed.

### `GetBaseProperty(propertyName: string) -> number?` {#get-base-property}

Returns the stored base value, or `nil` when the property does not exist.

### `GetResolvedProperty(propertyName: string) -> number?` {#get-resolved-property}

Returns the current value after tag resolution, or `nil` when the property does not exist. Runtime decisions should normally read this value.

### `GetResolvedProperties() -> {[string]: number}` {#get-resolved-properties}

Returns a frozen snapshot of all current resolved values. Later controller changes do not mutate the snapshot.

### `HasProperty(propertyName: string) -> boolean` {#has-property}

Returns whether a property entry exists. A tag modifier does not create a custom property; `SetBaseProperty` does.

### `Destroy() -> ()` {#destroy}

Disconnects tag observers and destroys owned events. Repeated calls are no-ops. Normal gameplay code should let Actor teardown call this method.

## Events

### `OnBasePropertyChanged: Event<Actor, string, number?, number>` {#on-base-property-changed}

Fires when a base value changes.

### `OnResolvedPropertyChanged: Event<Actor, string, number?, number>` {#on-resolved-property-changed}

Fires when a resolved value changes.

### `OnPropertyChanged: Event<PropertyChange>` {#on-property-changed}

Fires when a base or resolved value changes.

## Related

- [Property Runtime guide](/Property/property-runtime)
- [Tag Controller](../Tags/tag-controller)
- [Tag Registry](../Tags/tag-registry)
