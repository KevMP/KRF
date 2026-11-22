---
title: Schemas
sidebar_label: Guide
---

# Schemas

Use a Schema to declare the data a replication domain publishes or a request accepts. KRF checks each value against that shape and its bounds, so a missing realm, an extra field or an oversized list is rejected at the network boundary.

`KRF.Schema` constructs definitions for domain state and events, Commands, Hints and Action parameters. The system using the definition compiles it and checks runtime values.

## Describe the data the operation needs

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = require(ReplicatedStorage.Packages.KRF)
local Schema = KRF.Schema
local RealmState = Schema.Struct({
	realm = Schema.U8,
	sect = Schema.Optional(Schema.String(32)),
})
```

This accepts a realm from 0 to 255 and an optional sect name of at most 32 bytes. `{ realm = 1 }` is valid. A record missing `realm`, containing an extra field, or supplying a number for `sect` is invalid. Optional allows absence; it inserts no default and keeps the inner value's constraints.

Use an integer width for counts and IDs, a float for fractional measurements, and an Enum for a fixed vocabulary. Every number must be finite. A String's bound counts bytes, so a UTF-8 name can take more bytes than characters.

There is no unrestricted Any or generic Table schema. For Roblox values such as a direction, declare the numeric components the operation actually needs, then reconstruct or interpret them in game code. Instance references do not belong in these semantic payloads.

## Give collections useful bounds

Use `Array` when order is meaningful:

```lua
local RankedActors = Schema.Array(Schema.String(64), 8)
```

Its values must form a dense list with no holes or record keys. Use `Map` when a key identifies an entry regardless of position:

```lua
local Scores = Schema.Map(Schema.String(64), Schema.U16, 16)
```

This describes at most 16 ID-to-score entries. Supported Map keys are bounded strings, Enums and integers. Empty runtime collections are fine; their declared maxima must be positive.

Optional elements do not create nullable holes in Luau tables: assigning nil removes the entry. Keep the entry present and put the optional value inside it:

```lua
local Party = Schema.Array(Schema.Struct({
	actorId = Schema.String(64),
	role = Schema.Optional(Schema.Enum({ "Support", "Striker" })),
}), 4)
```

Each member still has an Actor ID; its role may be absent. The same approach works for Map values that need an optional field.

Choose bounds from gameplay needs. Very large legal maxima can still exceed a transport's payload budget or KRF's aggregate processing bounds. A constructor succeeding does not promise that every system can transport its maximum value.

## Keep the contract stable

Constructors validate and return owned immutable definitions. They copy supplied field maps and Enum arrays, so changing those source tables later does not change the contract. Constructing a schema does not freeze a table you intend to send. Invalid construction throws; catalog startup reports its own validation failures separately.

KRF does not coerce values to fit. `"2"` is not an integer, false is a present boolean, and an undeclared Struct field is not silently discarded. At network boundaries, admitted data is copied or encoded under the owning system's contract so later caller mutation cannot alter queued work.

Struct fields and Enum membership are normalized deterministically; declaration order does not define a public wire layout. Shared schema children are supported, recursive cycles are not. Buffer layout and codec implementation remain framework-owned.

See the [Schema API](./api) for exact ranges, constructors and failures.
