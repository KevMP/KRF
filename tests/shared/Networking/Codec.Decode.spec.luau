--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF

local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local SharedNetworkingTypes = require(KRF.shared.Networking.types)
local Schema: SharedNetworkingTypes.Schema = require(KRF.shared.Networking.Schema)
local TestUtils = require(script.Parent.Parent.Utils.Networking.CodecTestUtils)

type TruncationCase = { name: string, schema: SharedNetworkingTypes.SchemaDefinition, value: any }
local truncationCases: { TruncationCase } = {
	{ name = "U32", schema = Schema.U32, value = 123 },
	{ name = "F64", schema = Schema.F64, value = 1.25 },
	{ name = "String", schema = Schema.String(8), value = "abcd" },
	{ name = "Array", schema = Schema.Array(Schema.U16, 3), value = { 0, 1, 65535 } },
	{ name = "Map", schema = Schema.Map(Schema.U8, Schema.U16, 2), value = { [0] = 1, [2] = 65535 } },
	{ name = "present Optional", schema = Schema.Optional(Schema.U32), value = 12 },
	{
		name = "nested Struct",
		schema = Schema.Struct({ records = Schema.Array(Schema.Struct({ text = Schema.String(4) }), 2) }),
		value = { records = { { text = "full" }, { text = "last" } } },
	},
}
for _, testCase: TruncationCase in truncationCases do
	it("rejects every truncation of " .. testCase.name .. " without reading beyond the supplied limit", function()
		local codec: SharedNetworkingTypes.CompiledCodec = TestUtils.compile(testCase.schema)
		local encoded: buffer = TestUtils.encode(codec, testCase.value)
		for limit: number = 0, buffer.len(encoded) - 1 do
			-- Physical bytes remain available: only the logical boundary truncates.
			TestUtils.expectReadFailure(codec, encoded, 0, limit, "CodecTruncated")
			local physicallyTruncated: buffer = buffer.create(limit)
			buffer.copy(physicallyTruncated, 0, encoded, 0, limit)
			TestUtils.expectReadFailure(codec, physicallyTruncated, 0, limit, "CodecTruncated")
		end
	end)
end

it("rejects invalid read boundaries before invoking buffer operations", function()
	local codec: SharedNetworkingTypes.CompiledCodec = TestUtils.compile(Schema.U8)
	local source: buffer = buffer.create(2)
	local invalidBounds: { { number } } =
		{ { -1, 2 }, { 0.5, 2 }, { 2, 1 }, { 0, 3 }, { 0, 1.5 }, { 0, -1 }, { math.huge, 2 }, { 0, 0 / 0 } }
	for _, bounds: { number } in invalidBounds do
		TestUtils.expectReadFailure(codec, source, bounds[1], bounds[2], "CodecReadBoundsInvalid")
	end
end)

it("rejects non-canonical Boolean and Optional presence bytes", function()
	local source: buffer = buffer.create(1)
	for _, encoded: number in { 2, 255 } do
		buffer.writeu8(source, 0, encoded)
		TestUtils.expectReadFailure(TestUtils.compile(Schema.Boolean), source, 0, 1, "CodecBooleanInvalid")
		TestUtils.expectReadFailure(
			TestUtils.compile(Schema.Optional(Schema.U8)),
			source,
			0,
			1,
			"CodecOptionalPresenceInvalid"
		)
	end
end)

it("rejects an Enum ordinal outside its membership", function()
	local codec: SharedNetworkingTypes.CompiledCodec = TestUtils.compile(Schema.Enum({ "Idle", "Running" }))
	local source: buffer = TestUtils.encode(codec, "Idle")
	buffer.fill(source, 0, 255)
	TestUtils.expectReadFailure(codec, source, 0, buffer.len(source), "CodecEnumOrdinalInvalid")
end)

type LengthCase = { name: string, schema: SharedNetworkingTypes.SchemaDefinition, empty: any, reason: string }
local lengthCases: { LengthCase } = {
	{ name = "String", schema = Schema.String(2), empty = "", reason = "SchemaStringTooLong" },
	{ name = "Array", schema = Schema.Array(Schema.U8, 2), empty = {}, reason = "SchemaArrayTooLong" },
	{ name = "Map", schema = Schema.Map(Schema.U8, Schema.U8, 2), empty = {}, reason = "SchemaMapTooLarge" },
}
for _, testCase: LengthCase in lengthCases do
	it("rejects a declared " .. testCase.name .. " length over its bound before examining missing entries", function()
		local codec: SharedNetworkingTypes.CompiledCodec = TestUtils.compile(testCase.schema)
		local source: buffer = TestUtils.collectionPrefix(codec, testCase.empty, 255)
		TestUtils.expectReadFailure(codec, source, 0, buffer.len(source), testCase.reason)
	end)
end

it("rejects a bounded String length that exceeds the remaining bytes", function()
	local codec: SharedNetworkingTypes.CompiledCodec = TestUtils.compile(Schema.String(8))
	local source: buffer = TestUtils.collectionPrefix(codec, "", 8)
	TestUtils.expectReadFailure(codec, source, 0, buffer.len(source), "CodecTruncated")
end)

it("rejects duplicate Map keys instead of overwriting the first value", function()
	local codec: SharedNetworkingTypes.CompiledCodec = TestUtils.compile(Schema.Map(Schema.U8, Schema.Boolean, 2))
	local prefix: buffer = TestUtils.collectionPrefix(codec, {}, 2)
	local source: buffer = buffer.create(buffer.len(prefix) + 4)
	buffer.copy(source, 0, prefix)
	buffer.writeu8(source, buffer.len(prefix), 7)
	buffer.writeu8(source, buffer.len(prefix) + 1, 0)
	buffer.writeu8(source, buffer.len(prefix) + 2, 7)
	buffer.writeu8(source, buffer.len(prefix) + 3, 1)
	TestUtils.expectReadFailure(codec, source, 0, buffer.len(source), "CodecMapDuplicateKey")
end)

it("rejects absent Optional Array entries rather than creating holes", function()
	local codec: SharedNetworkingTypes.CompiledCodec = TestUtils.compile(Schema.Array(Schema.Optional(Schema.U8), 2))
	local prefix: buffer = TestUtils.collectionPrefix(codec, {}, 1)
	local source: buffer = buffer.create(buffer.len(prefix) + 1)
	buffer.copy(source, 0, prefix)
	buffer.writeu8(source, buffer.len(prefix), 0)
	TestUtils.expectReadFailure(codec, source, 0, buffer.len(source), "CodecCollectionEntryAbsent")
end)

it("rejects absent Optional Map values rather than silently deleting declared entries", function()
	local codec: SharedNetworkingTypes.CompiledCodec =
		TestUtils.compile(Schema.Map(Schema.U8, Schema.Optional(Schema.U8), 2))
	local prefix: buffer = TestUtils.collectionPrefix(codec, {}, 1)
	local source: buffer = buffer.create(buffer.len(prefix) + 2)
	buffer.copy(source, 0, prefix)
	buffer.writeu8(source, buffer.len(prefix), 7)
	buffer.writeu8(source, buffer.len(prefix) + 1, 0)
	TestUtils.expectReadFailure(codec, source, 0, buffer.len(source), "CodecCollectionEntryAbsent")
end)

it("rejects non-finite floating point bit patterns on decode", function()
	for _, definition: SharedNetworkingTypes.SchemaDefinition in { Schema.F32, Schema.F64 } do
		local codec: SharedNetworkingTypes.CompiledCodec = TestUtils.compile(definition)
		local source: buffer = buffer.create(codec.maxSizeBytes)
		for _, value: number in { math.huge, -math.huge, 0 / 0 } do
			if definition.kind == "F32" then
				buffer.writef32(source, 0, value)
			else
				buffer.writef64(source, 0, value)
			end
			TestUtils.expectReadFailure(codec, source, 0, buffer.len(source), "SchemaNumberMustBeFinite")
		end
	end
end)

it("rejects malformed data at depth without throwing and remains usable afterward", function()
	local definition: SharedNetworkingTypes.SchemaDefinition = Schema.U32
	local value: any = 42
	for _ = 1, 32 do
		definition = Schema.Struct({ child = Schema.Optional(Schema.Array(definition, 1)) })
		value = { child = { value } }
	end
	local codec: SharedNetworkingTypes.CompiledCodec = TestUtils.compile(definition)
	local encoded: buffer = TestUtils.encode(codec, value)
	TestUtils.expectReadFailure(codec, encoded, 0, buffer.len(encoded) - 1, "CodecTruncated")
	TestUtils.expectRoundTrip(codec, value)
end)

it("returns the end of one value and leaves following bytes for the next codec", function()
	local codec: SharedNetworkingTypes.CompiledCodec = TestUtils.compile(Schema.U16)
	local source: buffer = buffer.create(4)
	buffer.writeu16(source, 0, 65535)
	buffer.writeu16(source, 2, 42)
	local first: any, firstOffset: number?, firstReason: string? = codec.Read(source, 0, 4)
	local second: any, secondOffset: number?, secondReason: string? = codec.Read(source, 2, 4)
	expect(first).toBe(65535)
	expect(firstOffset).toBe(2)
	expect(firstReason).toBeNil()
	expect(second).toBe(42)
	expect(secondOffset).toBe(4)
	expect(secondReason).toBeNil()
end)

it("rejects enormous zero-byte collection work even when the declared schema bound permits the count", function()
	local codec: SharedNetworkingTypes.CompiledCodec =
		TestUtils.compile(Schema.Array(Schema.Struct({}), 9007199254740991))
	local source: buffer = TestUtils.collectionPrefix(codec, {}, 2 ^ 40)
	TestUtils.expectReadFailure(codec, source, 0, buffer.len(source), "CodecDecodeWorkExceeded")
	TestUtils.expectRoundTrip(codec, { {}, {} })
end)
