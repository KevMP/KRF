# Schema

`Schema` constructs immutable bounded data definitions for domain state and semantic event payloads.

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Schema = require(ReplicatedStorage.Packages.KRF.shared.Networking.Schema)
```

The module and all returned definitions are frozen, including nested schema data. Constructors copy supplied tables without freezing or retaining mutable caller-owned collections. Runtime values are validated against these definitions without coercion or mutation.

`SchemaDefinition` is exported by this module and by `KRF.shared.Networking.types`. Constructors return a definition, not a validator or an encoded buffer.

## Members

| Kind | Signature |
| --- | --- |
| Property | [`Boolean: SchemaDefinition`](#boolean) |
| Property | [`U8: SchemaDefinition`](#u8) |
| Property | [`U16: SchemaDefinition`](#u16) |
| Property | [`U32: SchemaDefinition`](#u32) |
| Property | [`I8: SchemaDefinition`](#i8) |
| Property | [`I16: SchemaDefinition`](#i16) |
| Property | [`I32: SchemaDefinition`](#i32) |
| Property | [`F32: SchemaDefinition`](#f32) |
| Property | [`F64: SchemaDefinition`](#f64) |
| Method | [`String(maxBytes: number) -> SchemaDefinition`](#string) |
| Method | [`Enum(values: {string}) -> SchemaDefinition`](#enum) |
| Method | [`Optional(inner: SchemaDefinition) -> SchemaDefinition`](#optional) |
| Method | [`Struct(fields: {[string]: SchemaDefinition}) -> SchemaDefinition`](#struct) |
| Method | [`Array(element: SchemaDefinition, maxLength: number) -> SchemaDefinition`](#array) |
| Method | [`Map(key: SchemaDefinition, value: SchemaDefinition, maxEntries: number) -> SchemaDefinition`](#map) |

## Properties

### `Boolean: SchemaDefinition` {#boolean}

Accepts only `true` and `false`; numbers and strings are not coerced.

### `U8: SchemaDefinition` {#u8}

Accepts finite integral numbers in `[0, 255]`, inclusive.

### `U16: SchemaDefinition` {#u16}

Accepts finite integral numbers in `[0, 65535]`, inclusive.

### `U32: SchemaDefinition` {#u32}

Accepts finite integral numbers in `[0, 4294967295]`, inclusive.

### `I8: SchemaDefinition` {#i8}

Accepts finite integral numbers in `[-128, 127]`, inclusive.

### `I16: SchemaDefinition` {#i16}

Accepts finite integral numbers in `[-32768, 32767]`, inclusive.

### `I32: SchemaDefinition` {#i32}

Accepts finite integral numbers in `[-2147483648, 2147483647]`, inclusive.

### `F32: SchemaDefinition` {#f32}

Accepts finite numbers in `[-3.4028234663852886e38, 3.4028234663852886e38]`, inclusive. Fractions are allowed. Validation checks range, not whether the original Luau value is exactly representable at 32-bit precision.

### `F64: SchemaDefinition` {#f64}

Accepts finite Luau numbers.

Both float schemas reject NaN and positive/negative infinity. Every non-Optional primitive rejects `nil` and values of the wrong type.

## Methods

### `String(maxBytes: number) -> SchemaDefinition` {#string}

Accepts strings whose byte length is at most `maxBytes`, including the empty string. The limit counts UTF-8 bytes, not characters.

`maxBytes` must be a positive safe integer in `[1, 9007199254740991]`. Missing, non-numeric, fractional, non-finite, out-of-range, zero, or negative bounds throw `SchemaStringMaxBytesInvalid`.

### `Enum(values: {string}) -> SchemaDefinition` {#enum}

Accepts exactly the declared strings. Membership is copied and sorted deterministically; declaration order does not define a wire code.

| Constructor rejection | Reason |
| --- | --- |
| Non-table, holes, non-array keys | `SchemaEnumValuesMustBeArray` |
| Empty array | `SchemaEnumValuesCannotBeEmpty` |
| Non-string or empty member | `SchemaEnumValueInvalid` |
| Repeated member | `SchemaEnumValueDuplicate` |

An empty runtime string is valid for `String`, but cannot be an Enum member.

### `Optional(inner: SchemaDefinition) -> SchemaDefinition` {#optional}

Accepts `nil` or any value accepted by `inner`. A Struct field directly wrapped in `Optional` may be absent; supplied values retain every constraint of `inner`. `false` and `0` are present values, and no default is inserted.

An invalid `inner` throws its schema-definition rejection reason; see [constructor failures](#constructor-failures).

### `Struct(fields: {[string]: SchemaDefinition}) -> SchemaDefinition` {#struct}

Accepts a table containing only the declared fields. Every field is required unless its immediate schema is `Optional`. Each stored field value validates recursively; `false` and `0` are not missing. Metatable-provided values do not satisfy required fields.

`fields` must be a table keyed by non-empty strings. Empty `fields` is valid and accepts only an empty record. Non-table fields throw `SchemaStructFieldsMustBeTable`; invalid field names throw `SchemaStructFieldNameInvalid`; invalid children throw their schema-definition rejection reason.

### `Array(element: SchemaDefinition, maxLength: number) -> SchemaDefinition` {#array}

Accepts a dense ordered table of at most `maxLength` recursively valid elements, including an empty table. Stored keys must be exactly `1` through the array's length. Holes, zero/negative/fractional indices, and record keys are invalid. Optional elements do not permit holes.

`maxLength` must be a positive safe integer in `[1, 9007199254740991]`; invalid bounds throw `SchemaArrayMaxLengthInvalid`. An invalid `element` throws its schema-definition rejection reason.

### `Map(key: SchemaDefinition, value: SchemaDefinition, maxEntries: number) -> SchemaDefinition` {#map}

Accepts an unordered table with at most `maxEntries` stored entries, including an empty table. Every key and value validates against its respective schema. Entries with `false` values count toward the limit; `nil` removes an entry in Luau.

Supported key schemas are `String`, `Enum`, `U8`, `U16`, `U32`, `I8`, `I16`, and `I32`. Boolean, float, Optional, Struct, Array, and Map keys throw `SchemaMapKeyUnsupported`. Integer keys obey their declared range; keys are not coerced between strings and numbers.

`maxEntries` must be a positive safe integer in `[1, 9007199254740991]`; invalid bounds throw `SchemaMapMaxEntriesInvalid`. Invalid key/value definitions throw their schema-definition rejection reason.

## Constructor failures {#constructor-failures}

Constructors throw on invalid definitions; they do not return `nil, reason`. Composite constructors recursively validate supplied children and can throw the following shared reasons:

| Reason | Cause |
| --- | --- |
| `SchemaDefinitionMissing` | A required child definition is `nil` |
| `SchemaDefinitionMustBeTable` | A supplied child definition is not a table |
| `SchemaKindInvalid` | Missing or unsupported `kind` |
| `SchemaFieldUnknown` | A definition contains a field not declared for its kind |
| `SchemaRecursiveDefinition` | Recursive definition cycle |
| `SchemaDepthExceeded` | Excessive structural nesting; the limit is private |

Child constructors' structural rejection reasons also propagate. Startup compilation performs an additional aggregate encoded-size check: failure to derive a conservative bound with exact safe-integer arithmetic rejects startup with `SchemaEncodedSizeInvalid`, even if construction succeeded. The encoded byte layout is private.

## Related

- [Bounded schemas guide](/Networking/schemas)
- [Replication domains guide](/Networking/replication-domains)
