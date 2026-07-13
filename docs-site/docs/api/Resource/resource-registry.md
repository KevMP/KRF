---
sidebar_position: 1
---

# Resource Registry

`ResourceRegistry` validates and stores the server-lifetime catalog used to create actor-scoped resources. Load it once during startup, before constructing `ResourceController` instances.

## Import

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF

local ResourceRegistry = require(KRF.server.Resource.ResourceRegistry)
```

## Members

| Kind | Signature |
| --- | --- |
| Method | [`Load(definitions: {ResourceDefinition}) -> (boolean, string?)`](#load) |
| Method | [`IsLoaded() -> boolean`](#is-loaded) |
| Method | [`Get(resourceId: string) -> LoadedResourceDefinition?`](#get) |
| Method | [`GetAll() -> {LoadedResourceDefinition}`](#get-all) |
| Method | [`GetAllById() -> {[string]: LoadedResourceDefinition}`](#get-all-by-id) |

## Methods

### `Load(definitions: {ResourceDefinition}) -> (boolean, string?)` {#load}

Validates the whole catalog, normalizes defaults, freezes the loaded definitions, and commits them in input order.

**Returns**

- `true, nil`: the full catalog committed.
- `false, "ResourceDefinitionsAlreadyLoaded"`: a catalog already committed.
- `false, reason`: a definition failed validation; nothing from this call committed and `IsLoaded()` remains `false`.

Validation reasons identify the field and rule, including missing ids, duplicate ids, invalid visibility, malformed sources, non-finite numbers, invalid default bounds, and out-of-bounds initial values.

### `IsLoaded() -> boolean` {#is-loaded}

Returns `true` only after a successful load.

### `Get(resourceId: string) -> LoadedResourceDefinition?` {#get}

Returns the frozen normalized definition, or `nil` for an unknown id.

### `GetAll() -> {LoadedResourceDefinition}` {#get-all}

Returns the frozen definition array in load order.

### `GetAllById() -> {[string]: LoadedResourceDefinition}` {#get-all-by-id}

Returns the frozen id-indexed catalog.

## Related

- [Resource Controller](./resource-controller)
- [Resource Registry guide](/Resource/resource-registry)
- [Resource Runtime guide](/Resource/resource-runtime)
