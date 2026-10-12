---
sidebar_position: 1
---

# Bounded schemas

`Schema` describes the meaning and limits of replicated state and semantic event payloads. Every accepted schema has a finite maximum encoded size that KRF can account for exactly.

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Schema = require(ReplicatedStorage.Packages.KRF.shared.Networking.Schema)
```

## Vocabulary

| Schema | Accepted value |
| --- | --- |
| `Boolean` | `true` or `false` |
| `U8`, `U16`, `U32` | Integers from `0` through `255`, `65535`, or `4294967295` |
| `I8`, `I16`, `I32` | Integers in `[-128, 127]`, `[-32768, 32767]`, or `[-2147483648, 2147483647]` |
| `F32` | Finite numbers within the 32-bit float range |
| `F64` | Finite Luau numbers |
| `String(maxBytes)` | Strings with at most `maxBytes` bytes, including an empty string |
| `Enum(values)` | One of the declared non-empty semantic strings |
| `Optional(inner)` | `nil` or a value accepted by `inner` |
| `Struct(fields)` | A fixed record containing only the declared fields |
| `Array(element, maxLength)` | A dense ordered array of accepted elements |
| `Map(key, value, maxEntries)` | An unordered keyed collection with accepted keys and values |

Integer widths occupy one, two, or four bytes; float widths occupy four or eight. Choose the representation for the value's range and precision. Integer validation rejects fractions and out-of-range values; floating-point validation rejects NaN and both infinities.

String bounds count bytes, including UTF-8's multiple bytes per character. Collection bounds and string bounds must be positive safe integers. Empty runtime strings, arrays, and maps remain valid even though their declared bounds must be positive.

## Records and collections

`Struct` requires every non-optional field and rejects undeclared fields. Zero and `false` are present values. Mark nullable fields with `Optional`; ordinary schemas do not implicitly accept `nil`.

```lua
local CombatState = Schema.Struct({
	blocking = Schema.Boolean,
	guard = Schema.F32,
	mode = Schema.Enum({ "Idle", "Blocking", "Stunned" }),
	targetId = Schema.Optional(Schema.String(64)),
	effects = Schema.Map(
		Schema.Enum({ "Burn", "Poison", "Slow" }),
		Schema.Struct({ stacks = Schema.U8, remaining = Schema.F32 }),
		16
	),
})
```

| Choose | Meaning | Structural comparison |
| --- | --- | --- |
| `Array` | Position and order matter | Compare the ordered value; replacement can represent a change |
| `Map` | Semantic keys identify entries | Compare additions, updates, and removals by key |

Arrays use exactly the indices `1` through their length. Holes, zero or negative indices, fractional indices, and extra record keys are invalid. `Optional` elements do not make an array containing holes dense.

Map keys support `String`, `Enum`, and the six integer schemas. Boolean, float, Optional, and collection schemas are unsupported keys. A Map's bound counts entries, including entries whose value is `false`.

## Ownership and admission

Constructors validate structure and return immutable owned definitions. Changing the source Enum array or Struct field table cannot change the constructed schema, and construction does not freeze those caller-owned tables.

During [server startup](../initializing-krf), KRF recursively validates and compiles domain state and event schemas. Struct fields and Enum membership use deterministic ordering. Shared child definitions are supported; recursive cycles are rejected.

Byte bounds include the maximum contained values and conservative encoding overhead. Unsafe addition or multiplication rejects with `SchemaEncodedSizeInvalid`; an integer-looking finite result above `2^53 - 1` is insufficient. Excessive structural nesting rejects with `SchemaDepthExceeded`. The depth limit and exact encoded layout are private.

The compiled contract supports value validation and structural comparison without rediscovering field order, Enum membership, or collection bounds for each value. Runtime validation reads stored values without coercing, freezing, or modifying them.

KRF has no unrestricted `Any`, `Table`, `Dictionary`, or generic `Number` schema. Every value must have an explicit bounded shape. These schemas are data contracts for schema-driven buffer serialization; they do not expose buffer encoding, transport, byte offsets, or packet layouts to game code.

## Related

- [Schema API](/api/Networking/schema)
- [Replication domains](./replication-domains)
