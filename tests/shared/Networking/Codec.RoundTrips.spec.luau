--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF

local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local SharedNetworkingTypes = require(KRF.shared.Networking.types)
local Schema: SharedNetworkingTypes.Schema = require(KRF.shared.Networking.Schema)
local TestUtils = require(script.Parent.Parent.Utils.Networking.CodecTestUtils)

type RoundTripCase = { name: string, schema: SharedNetworkingTypes.SchemaDefinition, values: { any }, width: number? }
local primitiveCases: { RoundTripCase } = {
	{ name = "Boolean", schema = Schema.Boolean, values = { false, true }, width = 1 },
	{ name = "U8", schema = Schema.U8, values = { 0, 1, 255 }, width = 1 },
	{ name = "U16", schema = Schema.U16, values = { 0, 256, 65535 }, width = 2 },
	{ name = "U32", schema = Schema.U32, values = { 0, 65536, 4294967295 }, width = 4 },
	{ name = "I8", schema = Schema.I8, values = { -128, -1, 0, 127 }, width = 1 },
	{ name = "I16", schema = Schema.I16, values = { -32768, -1, 0, 32767 }, width = 2 },
	{ name = "I32", schema = Schema.I32, values = { -2147483648, -1, 0, 2147483647 }, width = 4 },
	{ name = "F32", schema = Schema.F32, values = { -1.5, 0, 1.25, 3.4028234663852886e38 }, width = 4 },
	{ name = "F64", schema = Schema.F64, values = { -1e300, 0, math.pi, 1e300 }, width = 8 },
}
for _, testCase: RoundTripCase in primitiveCases do
	it("round-trips " .. testCase.name .. " boundaries with an exact fixed size", function()
		local codec: SharedNetworkingTypes.CompiledCodec = TestUtils.compile(testCase.schema)
		expect(codec.fixedSizeBytes).toBe(testCase.width)
		expect(codec.maxSizeBytes).toBe(testCase.width)
		for _, value: any in testCase.values do
			TestUtils.expectRoundTrip(codec, value)
		end
	end)
end

it("rounds F32 through its supported representation without requiring F64 precision", function()
	local codec: SharedNetworkingTypes.CompiledCodec = TestUtils.compile(Schema.F32)
	local expected: buffer = buffer.create(4)
	buffer.writef32(expected, 0, 0.1)
	local encoded: buffer = TestUtils.encode(codec, 0.1)
	local decoded: any, offset: number?, reason: string? = codec.Read(encoded, 0, buffer.len(encoded))
	expect(decoded).toBe(buffer.readf32(expected, 0))
	expect(offset).toBe(4)
	expect(reason).toBeNil()
end)

local collectionCases: { RoundTripCase } = {
	{ name = "bounded byte String", schema = Schema.String(4), values = { "", "abcd", "\0x\0", "éé" } },
	{ name = "Enum", schema = Schema.Enum({ "Idle", "Blocking" }), values = { "Idle", "Blocking" } },
	{
		name = "Struct",
		schema = Schema.Struct({
			active = Schema.Boolean,
			count = Schema.U16,
			note = Schema.Optional(Schema.String(4)),
		}),
		values = { { active = false, count = 0 }, { active = true, count = 65535, note = "done" } },
	},
	{ name = "empty Struct", schema = Schema.Struct({}), values = { {} }, width = 0 },
	{ name = "Array", schema = Schema.Array(Schema.Boolean, 3), values = { {}, { false }, { true, false, true } } },
	{
		name = "integer-key Map",
		schema = Schema.Map(Schema.I16, Schema.Boolean, 3),
		values = { {}, { [0] = false, [-1] = true, [32767] = false } },
	},
	{
		name = "Enum-key Map",
		schema = Schema.Map(Schema.Enum({ "Burn", "Slow" }), Schema.U8, 2),
		values = { {}, { Burn = 0, Slow = 255 } },
	},
	{
		name = "present Optional collection entries",
		schema = Schema.Struct({
			array = Schema.Array(Schema.Optional(Schema.Boolean), 2),
			map = Schema.Map(Schema.String(4), Schema.Optional(Schema.U8), 2),
		}),
		values = { { array = { false, true }, map = { zero = 0, last = 255 } } },
	},
}
for _, testCase: RoundTripCase in collectionCases do
	it("round-trips " .. testCase.name .. " without changing consumer values", function()
		local codec: SharedNetworkingTypes.CompiledCodec = TestUtils.compile(testCase.schema)
		for _, value: any in testCase.values do
			TestUtils.expectRoundTrip(codec, value)
		end
	end)
end

it("distinguishes a successfully decoded absent Optional from decode failure", function()
	local codec: SharedNetworkingTypes.CompiledCodec = TestUtils.compile(Schema.Optional(Schema.Boolean))
	TestUtils.expectRoundTrip(codec, nil)
	TestUtils.expectRoundTrip(codec, false)
	TestUtils.expectRoundTrip(codec, true)
end)

it("round-trips nested Map, Array, Struct, Enum and Optional combinations", function()
	local codec: SharedNetworkingTypes.CompiledCodec =
		TestUtils.compile(Schema.Map(
			Schema.String(8),
			Schema.Array(
				Schema.Struct({
					mode = Schema.Enum({ "Idle", "Active" }),
					detail = Schema.Optional(Schema.Struct({ amount = Schema.F64 })),
				}),
				2
			),
			2
		))
	TestUtils.expectRoundTrip(codec, {
		alpha = { { mode = "Idle" }, { mode = "Active", detail = { amount = 0.5 } } },
		beta = {},
	})
end)

it("writes Struct fields positionally and Enum values as compact ordinals", function()
	local codec: SharedNetworkingTypes.CompiledCodec = TestUtils.compile(Schema.Struct({
		aVeryLongFieldName = Schema.U8,
		zAnotherLongFieldName = Schema.Enum({ "AReallyLongEnumValue", "AnotherLongEnumValue" }),
	}))
	local encoded: buffer =
		TestUtils.encode(codec, { aVeryLongFieldName = 42, zAnotherLongFieldName = "AnotherLongEnumValue" })
	expect(buffer.len(encoded) < string.len("aVeryLongFieldName")).toBe(true)
	expect(buffer.readu8(encoded, 0)).toBe(42)
	TestUtils.expectRoundTrip(codec, { aVeryLongFieldName = 42, zAnotherLongFieldName = "AReallyLongEnumValue" })
end)

it("reports finite integral maximum sizes for every composite kind", function()
	for _, testCase: RoundTripCase in collectionCases do
		local codec: SharedNetworkingTypes.CompiledCodec = TestUtils.compile(testCase.schema)
		expect(codec.maxSizeBytes >= 0 and codec.maxSizeBytes < math.huge).toBe(true)
		expect(codec.maxSizeBytes % 1).toBe(0)
	end
end)
