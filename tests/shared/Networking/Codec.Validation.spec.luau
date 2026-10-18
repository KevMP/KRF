--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF

local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local SharedNetworkingTypes = require(KRF.shared.Networking.types)
local Schema: SharedNetworkingTypes.Schema = require(KRF.shared.Networking.Schema)
local TestUtils = require(script.Parent.Parent.Utils.Networking.CodecTestUtils)

type InvalidCase = { name: string, schema: SharedNetworkingTypes.SchemaDefinition, value: any, reason: string }
local invalidCases: { InvalidCase } = {
	{ name = "Boolean number coercion", schema = Schema.Boolean, value = 1, reason = "SchemaValueTypeInvalid" },
	{ name = "U8 underflow", schema = Schema.U8, value = -1, reason = "SchemaIntegerOutOfRange" },
	{ name = "U8 overflow", schema = Schema.U8, value = 256, reason = "SchemaIntegerOutOfRange" },
	{ name = "U16 underflow", schema = Schema.U16, value = -1, reason = "SchemaIntegerOutOfRange" },
	{ name = "U16 overflow", schema = Schema.U16, value = 65536, reason = "SchemaIntegerOutOfRange" },
	{ name = "U32 underflow", schema = Schema.U32, value = -1, reason = "SchemaIntegerOutOfRange" },
	{ name = "U32 overflow", schema = Schema.U32, value = 4294967296, reason = "SchemaIntegerOutOfRange" },
	{ name = "I8 underflow", schema = Schema.I8, value = -129, reason = "SchemaIntegerOutOfRange" },
	{ name = "I8 overflow", schema = Schema.I8, value = 128, reason = "SchemaIntegerOutOfRange" },
	{ name = "I16 underflow", schema = Schema.I16, value = -32769, reason = "SchemaIntegerOutOfRange" },
	{ name = "I16 overflow", schema = Schema.I16, value = 32768, reason = "SchemaIntegerOutOfRange" },
	{ name = "I32 underflow", schema = Schema.I32, value = -2147483649, reason = "SchemaIntegerOutOfRange" },
	{ name = "I32 overflow", schema = Schema.I32, value = 2147483648, reason = "SchemaIntegerOutOfRange" },
	{ name = "fractional integer", schema = Schema.U32, value = 1.5, reason = "SchemaIntegerMustBeIntegral" },
	{ name = "numeric string", schema = Schema.U16, value = "1", reason = "SchemaValueTypeInvalid" },
	{ name = "F32 NaN", schema = Schema.F32, value = 0 / 0, reason = "SchemaNumberMustBeFinite" },
	{ name = "F32 infinity", schema = Schema.F32, value = math.huge, reason = "SchemaNumberMustBeFinite" },
	{ name = "F64 negative infinity", schema = Schema.F64, value = -math.huge, reason = "SchemaNumberMustBeFinite" },
	{ name = "F64 NaN", schema = Schema.F64, value = 0 / 0, reason = "SchemaNumberMustBeFinite" },
	{ name = "F32 positive overflow", schema = Schema.F32, value = 3.5e38, reason = "SchemaF32OutOfRange" },
	{ name = "F32 negative overflow", schema = Schema.F32, value = -3.5e38, reason = "SchemaF32OutOfRange" },
	{ name = "oversized String", schema = Schema.String(4), value = "abcde", reason = "SchemaStringTooLong" },
	{ name = "String byte overflow", schema = Schema.String(3), value = "éé", reason = "SchemaStringTooLong" },
	{ name = "invalid Enum", schema = Schema.Enum({ "Idle" }), value = "Flying", reason = "SchemaEnumValueInvalid" },
	{
		name = "missing Struct field",
		schema = Schema.Struct({ value = Schema.U8 }),
		value = {},
		reason = "SchemaStructFieldMissing",
	},
	{
		name = "undeclared Struct field",
		schema = Schema.Struct({ value = Schema.U8 }),
		value = { value = 0, extra = false },
		reason = "SchemaStructFieldUndeclared",
	},
	{
		name = "sparse Array",
		schema = Schema.Array(Schema.U8, 3),
		value = { [1] = 1, [3] = 3 },
		reason = "SchemaArrayMustBeDense",
	},
	{
		name = "Array record key",
		schema = Schema.Array(Schema.U8, 3),
		value = { [1] = 1, extra = 1 },
		reason = "SchemaArrayMustBeDense",
	},
	{
		name = "oversized Array",
		schema = Schema.Array(Schema.U8, 2),
		value = { 1, 2, 3 },
		reason = "SchemaArrayTooLong",
	},
	{
		name = "oversized Map",
		schema = Schema.Map(Schema.U8, Schema.U8, 1),
		value = { [0] = 1, [1] = 2 },
		reason = "SchemaMapTooLarge",
	},
	{
		name = "invalid Map key",
		schema = Schema.Map(Schema.U8, Schema.U8, 1),
		value = { [256] = 0 },
		reason = "SchemaIntegerOutOfRange",
	},
	{
		name = "invalid Map value",
		schema = Schema.Map(Schema.U8, Schema.U8, 1),
		value = { [0] = false },
		reason = "SchemaValueTypeInvalid",
	},
	{
		name = "invalid nested Optional",
		schema = Schema.Struct({ detail = Schema.Optional(Schema.Array(Schema.U8, 2)) }),
		value = { detail = { 0, 256 } },
		reason = "SchemaIntegerOutOfRange",
	},
}
for _, testCase: InvalidCase in invalidCases do
	it("rejects " .. testCase.name .. " in both measurement and writing with the N1 reason", function()
		local codec: SharedNetworkingTypes.CompiledCodec = TestUtils.compile(testCase.schema)
		local destination: buffer = buffer.create(codec.maxSizeBytes)
		local size: number?, measureReason: string? = codec.Measure(testCase.value)
		local offset: number?, writeReason: string? = codec.Write(testCase.value, destination, 0)
		expect(size).toBeNil()
		expect(measureReason).toBe(testCase.reason)
		expect(offset).toBeNil()
		expect(writeReason).toBe(testCase.reason)
	end)
end
