--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF

local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local SharedNetworkingTypes = require(KRF.shared.Networking.types)
local Schema: SharedNetworkingTypes.Schema = require(KRF.shared.Networking.Schema)
local Compiler: SharedNetworkingTypes.CodecCompiler = require(KRF.shared.Networking.CodecCompiler)
local SchemaTestUtils = require(script.Parent.Parent.Utils.Networking.SchemaTestUtils)
local CodecTestUtils = require(script.Parent.Parent.Utils.Networking.CodecTestUtils)

local MAX_SAFE_INTEGER: number = 9007199254740991
type CompatibilityCase = { name: string, definition: SharedNetworkingTypes.SchemaDefinition, value: any }

local cases: { CompatibilityCase } = {
	{ name = "Boolean", definition = Schema.Boolean, value = false },
	{ name = "U8", definition = Schema.U8, value = 255 },
	{ name = "U16", definition = Schema.U16, value = 65535 },
	{ name = "U32", definition = Schema.U32, value = 4294967295 },
	{ name = "I8", definition = Schema.I8, value = -128 },
	{ name = "I16", definition = Schema.I16, value = -32768 },
	{ name = "I32", definition = Schema.I32, value = -2147483648 },
	{ name = "F32", definition = Schema.F32, value = 1.25 },
	{ name = "F64", definition = Schema.F64, value = math.pi },
	{ name = "Enum", definition = Schema.Enum({ "Idle", "Active" }), value = "Idle" },
	{ name = "Optional", definition = Schema.Optional(Schema.U32), value = 0 },
	{ name = "empty Struct", definition = Schema.Struct({}), value = {} },
	{
		name = "fixed Struct",
		definition = Schema.Struct({ active = Schema.Boolean, count = Schema.U32 }),
		value = { active = false, count = 0 },
	},
	{
		name = "nested collections",
		definition = Schema.Struct({
			entries = Schema.Array(
				Schema.Map(Schema.String(4), Schema.Optional(Schema.Enum({ "Idle", "Active" })), 2),
				3
			),
		}),
		value = { entries = { { zero = "Idle" }, {} } },
	},
	{ name = "large String", definition = Schema.String(MAX_SAFE_INTEGER - 8), value = "" },
	{ name = "large Array", definition = Schema.Array(Schema.U8, MAX_SAFE_INTEGER - 8), value = { 0 } },
	{
		name = "large Map",
		definition = Schema.Map(Schema.U8, Schema.Struct({}), MAX_SAFE_INTEGER - 8),
		value = { [0] = {} },
	},
	{
		name = "safe-integer Array cardinality",
		definition = Schema.Array(Schema.Struct({}), MAX_SAFE_INTEGER),
		value = { {}, {} },
	},
}

for _, maximum: number in { 1, 255, 256, 65535, 65536, 4294967296 } do
	table.insert(
		cases,
		{ name = "String bound " .. tostring(maximum), definition = Schema.String(maximum), value = "" }
	)

	table.insert(
		cases,
		{ name = "Array bound " .. tostring(maximum), definition = Schema.Array(Schema.U8, maximum), value = {} }
	)

	table.insert(cases, {
		name = "Map bound " .. tostring(maximum),
		definition = Schema.Map(Schema.U8, Schema.Boolean, maximum),
		value = {},
	})
end

for _, testCase: CompatibilityCase in cases do
	it("keeps the " .. testCase.name .. " codec maximum within N1's compiled encoded-size bound", function()
		local schema: SharedNetworkingTypes.CompiledSchema = SchemaTestUtils.compile(testCase.definition)
		local codec: SharedNetworkingTypes.CompiledCodec?, reason: string? = Compiler.Compile(schema)
		expect(reason).toBeNil()
		assert(codec ~= nil, "Expected a compiled codec for a legal N1 schema")
		expect(codec.maxSizeBytes >= 0 and codec.maxSizeBytes < math.huge).toBe(true)
		expect(codec.maxSizeBytes % 1).toBe(0)
		expect(codec.maxSizeBytes <= schema.maxEncodedBytes).toBe(true)
		-- Values stay tiny even when their legal schema maximum is enormous.
		CodecTestUtils.expectRoundTrip(codec, testCase.value)
	end)
end

for _, count: number in { 256, 257 } do
	it("keeps " .. tostring(count) .. " Enum ordinals within the N1 maximum at a code-width boundary", function()
		local values: { string } = {}

		for index: number = 1, count do
			table.insert(values, "Value" .. tostring(index))
		end

		local schema: SharedNetworkingTypes.CompiledSchema = SchemaTestUtils.compile(Schema.Enum(values))
		local codec: SharedNetworkingTypes.CompiledCodec?, reason: string? = Compiler.Compile(schema)
		expect(reason).toBeNil()
		assert(codec ~= nil, "Expected an Enum codec")
		expect(codec.maxSizeBytes <= schema.maxEncodedBytes).toBe(true)
		CodecTestUtils.expectRoundTrip(codec, values[1])
		CodecTestUtils.expectRoundTrip(codec, values[count])
	end)
end
