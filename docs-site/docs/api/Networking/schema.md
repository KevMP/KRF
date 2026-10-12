# Schema

`Schema` constructs immutable bounded data definitions for domain state and semantic event payloads.

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Schema = require(ReplicatedStorage.Packages.KRF.shared.Networking.Schema)
```

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

Accepts Boolean values.

### `U8: SchemaDefinition` {#u8}

Accepts unsigned 8-bit integers.

### `U16: SchemaDefinition` {#u16}

Accepts unsigned 16-bit integers.

### `U32: SchemaDefinition` {#u32}

Accepts unsigned 32-bit integers.

### `I8: SchemaDefinition` {#i8}

Accepts signed 8-bit integers.

### `I16: SchemaDefinition` {#i16}

Accepts signed 16-bit integers.

### `I32: SchemaDefinition` {#i32}

Accepts signed 32-bit integers.

### `F32: SchemaDefinition` {#f32}

Accepts finite numbers within the 32-bit float range.

### `F64: SchemaDefinition` {#f64}

Accepts finite Luau numbers.

## Methods

### `String(maxBytes: number) -> SchemaDefinition` {#string}

Constructs a string schema with a positive safe-integer byte bound; invalid bounds throw `SchemaStringMaxBytesInvalid`.

### `Enum(values: {string}) -> SchemaDefinition` {#enum}

Constructs a finite membership schema from a dense non-empty array of unique non-empty strings; malformed membership throws a schema validation reason.

### `Optional(inner: SchemaDefinition) -> SchemaDefinition` {#optional}

Constructs a nullable schema around a valid contained definition.

### `Struct(fields: {[string]: SchemaDefinition}) -> SchemaDefinition` {#struct}

Constructs a fixed record schema from non-empty string field names and valid field definitions.

### `Array(element: SchemaDefinition, maxLength: number) -> SchemaDefinition` {#array}

Constructs a bounded dense array schema; invalid length bounds throw `SchemaArrayMaxLengthInvalid`.

### `Map(key: SchemaDefinition, value: SchemaDefinition, maxEntries: number) -> SchemaDefinition` {#map}

Constructs a bounded keyed collection; invalid entry bounds throw `SchemaMapMaxEntriesInvalid`, and unsupported keys throw `SchemaMapKeyUnsupported`.

## Related

- [Bounded schemas guide](/Networking/schemas)
- [Replication domains guide](/Networking/replication-domains)
