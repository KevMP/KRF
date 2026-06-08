---
sidebar_position: 1
---

# Tag Registry

`TagRegistry` stores the static tag catalog for the lifetime of the server.

Use it during startup to load tag definitions once, then query those definitions later when needed.

## Import

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF

local TagRegistry = require(KRF.server.Tags.TagRegistry)
```

## Methods

### `Load(definitions) -> (boolean, string?)`

Validates and loads the registry once.

Returns:

* `true, nil` on success
* `false, reason` if validation fails or the registry was already loaded

### `Get(tagId) -> TagDefinition?`

Returns a tag definition by id.

### `GetAll() -> {TagDefinition}`

Returns every loaded definition in registration order.

### `GetAllById() -> {[string]: TagDefinition}`

Returns every loaded definition indexed by id.

### `IsLoaded() -> boolean`

Reports whether the registry is already loaded.

## Key Type

```lua
type TagDefinition = {
	id: string,
	defaultDuration: number?,
	tickInterval: number?,
	duplicateBehavior: "Stack" | "Refresh" | "Ignore",
	maxStacks: number?,
	visibility: "ServerOnly" | "ClientVisible",
	onTick: ((Actor, number) -> ())?,
	properties: { [string]: PropertyModifier }?,
}
```

## Notes

`TagRegistry` only stores tag meaning. It does not apply or remove active tag state on actors. That runtime behavior belongs to `TagController`.

## Related

* [Tag Controller](./tag-controller)
* [Tag Registry concepts](/Tags/tag-registry)
