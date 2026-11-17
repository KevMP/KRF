# Property Registry

`PropertyRegistry` stores immutable numeric Property definitions for the server lifetime. Normal games supply definitions through [server configuration](/initializing-krf).

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = require(ReplicatedStorage.Packages.KRF)
local PropertyRegistry = KRF.PropertyRegistry
```

## Members

| Kind | Signature |
| --- | --- |
| Method | [`Load(definitions: {PropertyDefinition}) -> (boolean, string?)`](#load) |
| Method | [`Get(propertyId: string) -> PropertyDefinition?`](#get) |
| Method | [`GetAll() -> {PropertyDefinition}`](#get-all) |
| Method | [`GetAllById() -> {[string]: PropertyDefinition}`](#get-all-by-id) |
| Method | [`IsLoaded() -> boolean`](#is-loaded) |

### `Load(definitions: {PropertyDefinition}) -> (boolean, string?)` {#load}

**Infrastructure API.** Validates a dense array, merges built-ins and atomically installs owned, frozen definitions. Returns `true, nil`, or `false, reason` without installing any entries.

| Reason | Cause |
| --- | --- |
| `PropertyDefinitionsAlreadyLoaded` | A catalog already committed |
| `PropertyDefinitionsMustBeTable` | Collection is not a table |
| `PropertyDefinitionsMustBeArray` | Collection has gaps or non-array keys |
| `PropertyDefinitionMustBeTable` | Entry is not a table |
| `InvalidPropertyId` | ID is not a nonempty string |
| `PropertyIdAlreadyRegistered` | Game catalog repeats an ID |
| `PropertyDefaultBaseValueMustBeFiniteNumber` | Default is missing, nonnumeric or nonfinite |
| `PropertyAutoAssignMustBeBoolean` | Supplied `autoAssign` is not a boolean |
| `PropertyDefinitionFieldUnsupported` | Definition contains an unsupported field |

### `Get(propertyId: string) -> PropertyDefinition?` {#get}

Returns the frozen definition, or `nil` for an unregistered ID.

### `GetAll() -> {PropertyDefinition}` {#get-all}

Returns the frozen array: built-ins first, then custom definitions in authored order.

### `GetAllById() -> {[string]: PropertyDefinition}` {#get-all-by-id}

Returns the frozen ID-indexed catalog.

### `IsLoaded() -> boolean` {#is-loaded}

Returns whether a catalog has committed successfully.

See [Property authoring](/Property/property-registry) and [PropertyController](./property-controller).
