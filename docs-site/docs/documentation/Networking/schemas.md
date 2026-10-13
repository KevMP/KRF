---
sidebar_position: 1
---

# Bounded schemas

Use `Schema` to describe the values your replication domain exposes: fixed records, nullable fields, and collections with explicit limits. Choose a shape that matches your gameplay data, then use it for domain state or an event payload.

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Schema = require(ReplicatedStorage.Packages.KRF.shared.Networking.Schema)
```

## Choose a schema

| Your data | Choose | Example |
| --- | --- | --- |
| A yes/no flag | `Boolean` | Blocking |
| A whole-number count or id | An integer width: `U8`, `U16`, `U32`, `I8`, `I16`, `I32` | Stack count, sequence id |
| A fractional measurement | `F32` or `F64` | Current guard, remaining seconds |
| Bounded text | `String(maxBytes)` | Display name |
| One of a fixed set of names | `Enum(values)` | `Idle`, `Blocking`, `Stunned` |
| A fixed record | `Struct(fields)` | Combat state |
| A value that can be absent | `Optional(inner)` | Current target |
| An ordered list | `Array(element, maxLength)` | Ranked targets |
| Entries identified by semantic keys | `Map(key, value, maxEntries)` | Effect id → effect state |

Choose the smallest integer width that covers the gameplay range. Unsigned widths accept non-negative values; signed widths include negative values. Use a float for fractional values, not to bypass integer bounds. All numeric values must be finite; see the [Schema API](/api/Networking/schema#properties) for exact ranges.

There is no unrestricted `Any`, `Table`, `Dictionary`, or generic `Number` schema. Every value has an explicit shape.

## Write a record with optional fields

```lua
local CombatState = Schema.Struct({
	blocking = Schema.Boolean,
	guard = Schema.F32,
	mode = Schema.Enum({ "Idle", "Blocking", "Stunned" }),
	targetId = Schema.Optional(Schema.String(64)),
})
```

`Struct` requires every field except those wrapped in `Optional` and rejects undeclared fields. For this schema, `{ blocking = false, guard = 0, mode = "Idle" }` is valid: `false` and `0` are present values, and `targetId` may be absent. Adding `debug = true` or omitting `guard` is invalid.

`Optional` accepts `nil` or a valid contained value. It does not supply a default, make the surrounding record optional, or relax the contained schema. `targetId = 123` is still invalid.

## Choose Array or Map

| Choose | Identity | Example | Comparison meaning |
| --- | --- | --- | --- |
| `Array` | Position in an ordered list | `Schema.Array(Schema.String(64), 8)` | Order matters; replacement can represent a change |
| `Map` | Semantic key | Effect name → effect state | Compare added, updated, and removed keys |

Use an Array for data such as an ordered target ranking. Values must occupy exactly `1` through the list length, without holes or record keys. Wrapping the element in `Optional` cannot represent a hole: assigning `nil` removes that Luau table entry.

Use a Map when an entry keeps its identity as other entries change:

```lua
local Effects = Schema.Map(
	Schema.Enum({ "Burn", "Poison", "Slow" }),
	Schema.Struct({ stacks = Schema.U8, remaining = Schema.F32 }),
	16
)
```

Here, `{ Burn = { stacks = 2, remaining = 1.5 } }` is valid. `Burn` is the entry's identity, not its position. Map keys support bounded `String`, `Enum`, and the six integer schemas; Boolean, float, Optional, and collection keys are unsupported.

## Set practical bounds

Every String, Array, and Map declares a positive integer maximum. Choose the limit your gameplay actually needs: for example, 64 bytes for a target id, eight ranked targets, or 16 concurrent effects. Bounds apply to each nested collection independently.

String limits count bytes, so UTF-8 characters can use more than one byte. Array limits count elements; Map limits count stored entries, including `false` values. Empty runtime strings, arrays, and maps are valid even though their declared maximum must be positive.

Explicit limits let KRF reject oversized values and determine a conservative upper bound on encoded size before runtime. Schemas describe semantic data for buffer serialization; games do not author packets or depend on byte offsets.

## Admission and safety

Constructors validate definitions and return immutable owned copies. Changing a source Enum array, Struct field table, or child descriptor cannot change the constructed schema; KRF does not freeze those caller-owned tables. Each kind permits only its declared fields. Unknown fields, including fields belonging to another kind, reject with `SchemaFieldUnknown`.

During [server startup](../initializing-krf), KRF recursively validates and compiles domain state and event schemas. Struct fields and Enum membership have deterministic ordering. Shared child definitions are supported; recursive cycles are not. Runtime value validation does not coerce, freeze, or modify supplied values.

| Admission failure | Meaning |
| --- | --- |
| Invalid String/Array/Map bound | Bounds must be positive safe integers, at most `2^53 - 1`; see each constructor's [failure contract](/api/Networking/schema#methods) |
| `SchemaRecursiveDefinition` | A definition contains a recursive cycle |
| `SchemaDepthExceeded` | Structural nesting exceeds the private admission limit |
| `SchemaEncodedSizeInvalid` | Startup cannot account for the aggregate byte bound with exact safe-integer arithmetic |

The byte bound includes conservative encoding overhead; it is an upper bound, not a promise of an exact encoded layout. A finite, integer-looking result is insufficient if its arithmetic exceeds the safe-integer range. Structurally valid constructors can still produce a schema rejected by this aggregate startup check.

## Related

- [Schema API](/api/Networking/schema)
- [Replication domains](./replication-domains)
