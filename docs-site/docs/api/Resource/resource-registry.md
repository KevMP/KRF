---
sidebar_position: 1
---

# Resource Registry

`ResourceRegistry` stores the static resource catalog for the lifetime of the server.

Use it during startup to load resource definitions once, then query those definitions later when needed.

## Import

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF

local ResourceRegistry = require(KRF.server.Resource.ResourceRegistry)
```

## Methods

### `Load(definitions) -> (boolean, string?)`

Validates and loads the registry once.

Returns:

* `true, nil` on success
* `false, reason` if validation fails or the registry was already loaded

### `Get(resourceId) -> LoadedResourceDefinition?`

Returns one loaded definition by id.

### `GetAll() -> {LoadedResourceDefinition}`

Returns every loaded definition in registration order.

### `GetAllById() -> {[string]: LoadedResourceDefinition}`

Returns every loaded definition indexed by id.

### `IsLoaded() -> boolean`

Reports whether the registry is already loaded.

## Key Types

```lua
type ResourceDefinition = {
	id: string,
	min: {
		value: number?,
		propertyName: string?,
		defaultBaseValue: number?,
	}?,
	max: {
		value: number?,
		propertyName: string?,
		defaultBaseValue: number?,
	},
	initialValue: number?,
	visibility: "ServerOnly" | "ClientVisible",
	autoAssign: boolean?,
	regen: {
		rate: {
			value: number?,
			propertyName: string?,
			defaultBaseValue: number?,
		},
	}?,
}

type LoadedResourceDefinition = ResourceDefinition & {
	min: {
		value: number?,
		propertyName: string?,
		defaultBaseValue: number?,
	},
	autoAssign: boolean,
}
```

## Related

* [Resource Registry concepts](/Resource/resource-registry)
