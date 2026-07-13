---
sidebar_position: 1
---

# Tag Registry

`TagRegistry` validates and stores the server-lifetime catalog that defines tag identity, duplication, timing, visibility, ticks, and property modifiers. Load it before constructing `TagController` instances.

## Import

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF

local TagRegistry = require(KRF.server.Tags.TagRegistry)
```

## Members

| Kind | Signature |
| --- | --- |
| Method | [`Load(definitions: {TagDefinition}) -> (boolean, string?)`](#load) |
| Method | [`IsLoaded() -> boolean`](#is-loaded) |
| Method | [`Get(tagId: string) -> TagDefinition?`](#get) |
| Method | [`GetAll() -> {TagDefinition}`](#get-all) |
| Method | [`GetAllById() -> {[string]: TagDefinition}`](#get-all-by-id) |

## Methods

### `Load(definitions: {TagDefinition}) -> (boolean, string?)` {#load}

Validates the complete catalog and commits it in input order.

**Returns**

- `true, nil`: the full catalog committed.
- `false, "TagDefinitionsAlreadyLoded"`: a catalog already committed.
- `false, reason`: validation failed; nothing from the call committed and `IsLoaded()` remains `false`.

Validation reasons identify missing or duplicate ids, invalid duration and tick values, invalid duplicate or visibility values, invalid `maxStacks`, and malformed modifiers.

The returned registry containers are frozen. Definitions remain the same table references supplied to `Load`; treat authored definitions as immutable after loading.

### `IsLoaded() -> boolean` {#is-loaded}

Returns `true` only after a successful load.

### `Get(tagId: string) -> TagDefinition?` {#get}

Returns the registered definition, or `nil` for an unknown id.

### `GetAll() -> {TagDefinition}` {#get-all}

Returns the frozen definition array in load order.

### `GetAllById() -> {[string]: TagDefinition}` {#get-all-by-id}

Returns the frozen id-indexed catalog.

## Related

- [Tag Controller](./tag-controller)
- [Tag Registry guide](/Tags/tag-registry)
- [Tag Runtime guide](/Tags/tag-runtime)
