--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF

local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local NetworkingTypes = require(KRF.shared.Networking.types)
local Schema: NetworkingTypes.Schema = require(KRF.shared.Networking.Schema)
local TestUtils = require(script.Parent.Parent.Utils.Networking.SchemaTestUtils)

type SchemaDefinition = NetworkingTypes.SchemaDefinition
type CompiledSchema = NetworkingTypes.CompiledSchema
type IntegerCase = { name: string, definition: SchemaDefinition, minimum: number, maximum: number }

local integers: { IntegerCase } = {
	{ name = "U8", definition = Schema.U8, minimum = 0, maximum = 255 },
	{ name = "U16", definition = Schema.U16, minimum = 0, maximum = 65535 },
	{ name = "U32", definition = Schema.U32, minimum = 0, maximum = 4294967295 },
	{ name = "I8", definition = Schema.I8, minimum = -128, maximum = 127 },
	{ name = "I16", definition = Schema.I16, minimum = -32768, maximum = 32767 },
	{ name = "I32", definition = Schema.I32, minimum = -2147483648, maximum = 2147483647 },
}

for _, integerCase: IntegerCase in integers do
	it(integerCase.name .. " accepts both legal boundaries, zero, and interior integers", function()
		local compiled: CompiledSchema = TestUtils.compile(integerCase.definition)
		TestUtils.expectValid(compiled, integerCase.minimum)
		TestUtils.expectValid(compiled, integerCase.minimum + 1)
		TestUtils.expectValid(compiled, 0)
		TestUtils.expectValid(compiled, -0)
		TestUtils.expectValid(compiled, integerCase.maximum - 1)
		TestUtils.expectValid(compiled, integerCase.maximum)
	end)
	it(integerCase.name .. " rejects the integer immediately below its legal range", function()
		local compiled: CompiledSchema = TestUtils.compile(integerCase.definition)
		TestUtils.expectInvalid(compiled, integerCase.minimum - 1, "SchemaIntegerOutOfRange")
	end)
	it(integerCase.name .. " rejects the integer immediately above its legal range", function()
		local compiled: CompiledSchema = TestUtils.compile(integerCase.definition)
		TestUtils.expectInvalid(compiled, integerCase.maximum + 1, "SchemaIntegerOutOfRange")
	end)
	it(integerCase.name .. " rejects positive and negative fractional values without rounding", function()
		local compiled: CompiledSchema = TestUtils.compile(integerCase.definition)
		TestUtils.expectInvalid(compiled, 0.5, "SchemaIntegerMustBeIntegral")
		TestUtils.expectInvalid(compiled, -0.5, "SchemaIntegerMustBeIntegral")
	end)
	it(integerCase.name .. " rejects NaN and both infinities", function()
		local compiled: CompiledSchema = TestUtils.compile(integerCase.definition)
		TestUtils.expectInvalid(compiled, 0 / 0, "SchemaNumberMustBeFinite")
		TestUtils.expectInvalid(compiled, math.huge, "SchemaNumberMustBeFinite")
		TestUtils.expectInvalid(compiled, -math.huge, "SchemaNumberMustBeFinite")
	end)
	it(integerCase.name .. " rejects missing values and does not coerce strings or booleans", function()
		local compiled: CompiledSchema = TestUtils.compile(integerCase.definition)
		TestUtils.expectInvalid(compiled, nil, "SchemaValueTypeInvalid")
		TestUtils.expectInvalid(compiled, "1", "SchemaValueTypeInvalid")
		TestUtils.expectInvalid(compiled, true, "SchemaValueTypeInvalid")
		TestUtils.expectInvalid(compiled, {}, "SchemaValueTypeInvalid")
	end)
end

it("Boolean accepts true and false while rejecting nil and truthy values of other types", function()
	local compiled: CompiledSchema = TestUtils.compile(Schema.Boolean)
	TestUtils.expectValid(compiled, true)
	TestUtils.expectValid(compiled, false)
	TestUtils.expectInvalid(compiled, nil, "SchemaValueTypeInvalid")
	TestUtils.expectInvalid(compiled, 0, "SchemaValueTypeInvalid")
	TestUtils.expectInvalid(compiled, 1, "SchemaValueTypeInvalid")
	TestUtils.expectInvalid(compiled, "true", "SchemaValueTypeInvalid")
	TestUtils.expectInvalid(compiled, {}, "SchemaValueTypeInvalid")
end)

type FloatCase = { name: string, definition: SchemaDefinition, maximum: number }
local floats: { FloatCase } = {
	{ name = "F32", definition = Schema.F32, maximum = 3.4028234663852886e38 },
	{ name = "F64", definition = Schema.F64, maximum = 1.7976931348623157e308 },
}
for _, floatCase: FloatCase in floats do
	it(floatCase.name .. " accepts finite positive and negative values including its representable limits", function()
		local compiled: CompiledSchema = TestUtils.compile(floatCase.definition)
		TestUtils.expectValid(compiled, 0)
		TestUtils.expectValid(compiled, -0)
		TestUtils.expectValid(compiled, 1.25)
		TestUtils.expectValid(compiled, -1.25)
		TestUtils.expectValid(compiled, floatCase.maximum)
		TestUtils.expectValid(compiled, -floatCase.maximum)
	end)
	it(floatCase.name .. " rejects NaN and both infinities", function()
		local compiled: CompiledSchema = TestUtils.compile(floatCase.definition)
		TestUtils.expectInvalid(compiled, 0 / 0, "SchemaNumberMustBeFinite")
		TestUtils.expectInvalid(compiled, math.huge, "SchemaNumberMustBeFinite")
		TestUtils.expectInvalid(compiled, -math.huge, "SchemaNumberMustBeFinite")
	end)
	it(floatCase.name .. " rejects nil and non-number values without coercion", function()
		local compiled: CompiledSchema = TestUtils.compile(floatCase.definition)
		TestUtils.expectInvalid(compiled, nil, "SchemaValueTypeInvalid")
		TestUtils.expectInvalid(compiled, "1.25", "SchemaValueTypeInvalid")
		TestUtils.expectInvalid(compiled, false, "SchemaValueTypeInvalid")
		TestUtils.expectInvalid(compiled, {}, "SchemaValueTypeInvalid")
	end)
end

it("F32 rejects finite values beyond its range even when F64 can represent them", function()
	local narrow: CompiledSchema = TestUtils.compile(Schema.F32)
	local wide: CompiledSchema = TestUtils.compile(Schema.F64)
	TestUtils.expectInvalid(narrow, 3.5e38, "SchemaF32OutOfRange")
	TestUtils.expectInvalid(narrow, -3.5e38, "SchemaF32OutOfRange")
	TestUtils.expectValid(wide, 3.5e38)
	TestUtils.expectValid(wide, -3.5e38)
end)

it("String accepts empty, interior, and exact-bound byte strings", function()
	local compiled: CompiledSchema = TestUtils.compile(Schema.String(4))
	TestUtils.expectValid(compiled, "")
	TestUtils.expectValid(compiled, "abc")
	TestUtils.expectValid(compiled, "abcd")
	TestUtils.expectValid(compiled, string.char(0, 255, 0, 255))
	TestUtils.expectInvalid(compiled, "abcde", "SchemaStringTooLong")
end)

it("String counts UTF-8 bytes rather than characters", function()
	local compiled: CompiledSchema = TestUtils.compile(Schema.String(4))
	local twoByteCharacter: string = utf8.char(233)
	local fourByteCharacter: string = utf8.char(128512)
	TestUtils.expectValid(compiled, twoByteCharacter .. twoByteCharacter)
	TestUtils.expectValid(compiled, fourByteCharacter)
	TestUtils.expectInvalid(compiled, fourByteCharacter .. "a", "SchemaStringTooLong")
	TestUtils.expectInvalid(compiled, twoByteCharacter .. twoByteCharacter .. twoByteCharacter, "SchemaStringTooLong")
end)

it("String rejects non-string values and implicit nil", function()
	local compiled: CompiledSchema = TestUtils.compile(Schema.String(4))
	TestUtils.expectInvalid(compiled, nil, "SchemaValueTypeInvalid")
	TestUtils.expectInvalid(compiled, 1234, "SchemaValueTypeInvalid")
	TestUtils.expectInvalid(compiled, false, "SchemaValueTypeInvalid")
	TestUtils.expectInvalid(compiled, {}, "SchemaValueTypeInvalid")
end)

it("Enum accepts declared semantic strings and rejects unknown, differently cased, and non-string values", function()
	local compiled: CompiledSchema = TestUtils.compile(Schema.Enum({ "Blocking", "Idle", "Stunned" }))
	TestUtils.expectValid(compiled, "Blocking")
	TestUtils.expectValid(compiled, "Idle")
	TestUtils.expectValid(compiled, "Stunned")
	TestUtils.expectInvalid(compiled, "Flying", "SchemaEnumValueInvalid")
	TestUtils.expectInvalid(compiled, "idle", "SchemaEnumValueInvalid")
	TestUtils.expectInvalid(compiled, "", "SchemaEnumValueInvalid")
	TestUtils.expectInvalid(compiled, 1, "SchemaValueTypeInvalid")
	TestUtils.expectInvalid(compiled, nil, "SchemaValueTypeInvalid")
end)
