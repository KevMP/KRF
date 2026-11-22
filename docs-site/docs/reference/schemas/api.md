---
title: Schema API
sidebar_label: API
---

# Schema API

`KRF.Schema` is a frozen shared module. Its primitive properties and constructor results are `KRF.SchemaDefinition` values, not standalone validators or codecs. Methods use dot syntax and throw on invalid definitions.

## Primitive definitions

| Property | Accepted values |
| --- | --- |
| `Boolean` | Exactly true or false |
| `U8` | Integer `[0, 255]` |
| `U16` | Integer `[0, 65535]` |
| `U32` | Integer `[0, 4294967295]` |
| `I8` | Integer `[-128, 127]` |
| `I16` | Integer `[-32768, 32767]` |
| `I32` | Integer `[-2147483648, 2147483647]` |
| `F32` | Finite number within `±3.4028234663852886e38`; encoding may round to 32-bit precision |
| `F64` | Finite Luau number |

Ranges are inclusive. No primitive coerces strings or accepts nil. Every numeric schema rejects NaN and infinity.

## Constructors

Every constructor returns `SchemaDefinition`; none accepts a runtime value to validate. Composite constructors validate their child definitions recursively. Returned definitions and nested data are frozen. Caller-owned definition tables are copied, not frozen in place.

| Signature | Accepted runtime value |
| --- | --- |
| `String(maxBytes: number)` | String of at most that many bytes; empty string allowed |
| `Enum(values: {string})` | Exactly one listed nonempty string; membership sorted deterministically |
| `Optional(inner: SchemaDefinition)` | Nil or a value accepted by inner |
| `Struct(fields: {[string]: SchemaDefinition})` | Record with only declared fields; all required except immediate Optional children |
| `Array(element: SchemaDefinition, maxLength: number)` | Dense ordered list from index 1 through its length, at most maxLength elements |
| `Map(key: SchemaDefinition, value: SchemaDefinition, maxEntries: number)` | At most maxEntries stored entries with valid keys and values |

String/Array/Map maxima must be positive safe integers in `[1, 9007199254740991]`. Bounds describe semantic admission, not guaranteed transport capacity. Startup separately accounts for conservative aggregate encoded size.

Enum values must be a nonempty dense array of distinct nonempty strings. Struct field names must be nonempty strings; an empty Struct is valid and accepts an empty record. Metatable-provided values do not satisfy required fields.

Map keys support String, Enum, U8/U16/U32 and I8/I16/I32. Boolean, floats, Optional and composite keys are unsupported. Keys retain their declared type: an integer key is not interchangeable with a numeric string. Entries containing false count; nil removes an entry. Optional Array elements or Map values do not permit missing collection entries on decode. Use an Optional Struct field inside a present entry instead.

Runtime validation reads stored entries. A metatable cannot supply required fields, hide undeclared fields or fill Array holes. Checking a value does not coerce, freeze or modify the caller's data; the system admitting that value separately owns its copy or encoded payload.

## Failures

Constructors throw a reason string rather than returning nil/reason.

| Reason | Cause |
| --- | --- |
| `SchemaStringMaxBytesInvalid` | Invalid String bound |
| `SchemaArrayMaxLengthInvalid` | Invalid Array bound |
| `SchemaMapMaxEntriesInvalid` | Invalid Map bound |
| `SchemaEnumValuesMustBeArray`, `SchemaEnumValuesCannotBeEmpty` | Invalid Enum array |
| `SchemaEnumValueInvalid`, `SchemaEnumValueDuplicate` | Invalid or repeated member |
| `SchemaStructFieldsMustBeTable`, `SchemaStructFieldNameInvalid` | Invalid Struct declaration |
| `SchemaMapKeyUnsupported` | Unsupported key kind |
| `SchemaDefinitionMissing`, `SchemaDefinitionMustBeTable` | Missing or invalid child |
| `SchemaKindInvalid`, `SchemaFieldUnknown` | Unsupported kind or unknown definition field |
| `SchemaRecursiveDefinition`, `SchemaDepthExceeded` | Cycle or excessive structural nesting |

Startup compilation can additionally reject `SchemaEncodedSizeInvalid` when aggregate size accounting cannot remain exact within safe-integer arithmetic. A valid constructor result can therefore still fail startup compilation or the using system's payload-size budget.

### Runtime value failures

The system using a Schema reports value failures; Schema itself exposes no public Validate, Encode or Decode method. Action requests can map these failures to `ActionPayloadInvalid`, while other APIs may propagate the specific reason.

| Reason | Cause |
| --- | --- |
| `SchemaValueTypeInvalid` | Value has the wrong Luau type |
| `SchemaNumberMustBeFinite`, `SchemaIntegerMustBeIntegral` | Non-finite number or fraction supplied to an integer schema |
| `SchemaIntegerOutOfRange`, `SchemaF32OutOfRange` | Number exceeds the declared numeric range |
| `SchemaStringTooLong`, `SchemaEnumValueInvalid` | String exceeds its byte bound or is not an Enum member |
| `SchemaStructFieldMissing`, `SchemaStructFieldUndeclared` | Missing required field or extra stored field |
| `SchemaArrayMustBeDense`, `SchemaArrayTooLong`, `SchemaMapTooLarge` | Invalid collection shape or bound exceeded |

Encoding and decoding also enforce private aggregate collection-work bounds, including nested collections of empty records. Legal metadata maxima do not disable those bounds; `CodecEncodeWorkExceeded` or `CodecDecodeWorkExceeded` identifies that limit. Collection decoding rejects absent Optional entries with `CodecCollectionEntryAbsent` rather than silently dropping entries or creating holes. These checks do not make the private wire layout a consumer API.
