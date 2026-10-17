--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF

local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local SharedNetworkingTypes = require(KRF.shared.Networking.types)
local Schema: SharedNetworkingTypes.Schema = require(KRF.shared.Networking.Schema)
local Validator: SharedNetworkingTypes.SchemaValidator = require(KRF.shared.Networking.utils.SchemaValidator)
local TestUtils = require(script.Parent.Parent.Utils.Networking.SchemaTestUtils)

type SchemaDefinition = SharedNetworkingTypes.SchemaDefinition
type CompiledSchema = SharedNetworkingTypes.CompiledSchema

it("Struct accepts complete nested state with false and zero-valued required fields", function()
	local compiled: CompiledSchema = TestUtils.compile(Schema.Struct({
		blocking = Schema.Boolean,
		guard = Schema.F32,
		effect = Schema.Struct({ stacks = Schema.U8, remaining = Schema.Optional(Schema.F32) }),
	}))
	TestUtils.expectValid(compiled, { blocking = false, guard = 0, effect = { stacks = 0 } })
	TestUtils.expectValid(compiled, { blocking = true, guard = 10, effect = { stacks = 2, remaining = 1.5 } })
end)

it("Struct rejects missing required fields without treating zero or false as missing", function()
	local compiled: CompiledSchema = TestUtils.compile(Schema.Struct({ active = Schema.Boolean, count = Schema.U8 }))
	TestUtils.expectInvalid(compiled, { active = false }, "SchemaStructFieldMissing")
	TestUtils.expectInvalid(compiled, { count = 0 }, "SchemaStructFieldMissing")
	TestUtils.expectInvalid(compiled, {}, "SchemaStructFieldMissing")
end)

it("Struct rejects invalid field types and undeclared fields at every nesting level", function()
	local compiled: CompiledSchema = TestUtils.compile(Schema.Struct({
		stats = Schema.Struct({ guard = Schema.F32 }),
	}))
	TestUtils.expectInvalid(compiled, { stats = { guard = true } }, "SchemaValueTypeInvalid")
	TestUtils.expectInvalid(compiled, { stats = { guard = 10 }, extra = false }, "SchemaStructFieldUndeclared")
	TestUtils.expectInvalid(compiled, { stats = { guard = 10, extra = false } }, "SchemaStructFieldUndeclared")
	TestUtils.expectInvalid(compiled, { stats = {} }, "SchemaStructFieldMissing")
	TestUtils.expectInvalid(compiled, { stats = { guard = 10 }, [1] = "extra" }, "SchemaStructFieldUndeclared")
end)

it("empty Struct accepts only an empty record and requires a table value", function()
	local compiled: CompiledSchema = TestUtils.compile(Schema.Struct({}))
	TestUtils.expectValid(compiled, {})
	TestUtils.expectInvalid(compiled, { extra = 1 }, "SchemaStructFieldUndeclared")
	TestUtils.expectInvalid(compiled, nil, "SchemaValueTypeInvalid")
	TestUtils.expectInvalid(compiled, true, "SchemaValueTypeInvalid")
end)

it("Optional accepts nil and valid contained values while retaining the contained validation contract", function()
	local compiled: CompiledSchema = TestUtils.compile(Schema.Optional(Schema.U8))
	TestUtils.expectValid(compiled, nil)
	TestUtils.expectValid(compiled, 0)
	TestUtils.expectValid(compiled, 255)
	TestUtils.expectInvalid(compiled, false, "SchemaValueTypeInvalid")
	TestUtils.expectInvalid(compiled, 256, "SchemaIntegerOutOfRange")
end)

it("Optional nested state validates both presence and all contained fields", function()
	local compiled: CompiledSchema = TestUtils.compile(Schema.Optional(Schema.Struct({ active = Schema.Boolean })))
	TestUtils.expectValid(compiled, nil)
	TestUtils.expectValid(compiled, { active = false })
	TestUtils.expectInvalid(compiled, {}, "SchemaStructFieldMissing")
	TestUtils.expectInvalid(compiled, { active = false, extra = 1 }, "SchemaStructFieldUndeclared")
end)

it("Optional Boolean preserves false as a present valid value", function()
	local compiled: CompiledSchema = TestUtils.compile(Schema.Optional(Schema.Boolean))
	TestUtils.expectValid(compiled, nil)
	TestUtils.expectValid(compiled, false)
	TestUtils.expectValid(compiled, true)
	TestUtils.expectInvalid(compiled, 0, "SchemaValueTypeInvalid")
end)

it("Array accepts empty, dense interior, and maximum-length ordered values", function()
	local compiled: CompiledSchema = TestUtils.compile(Schema.Array(Schema.U16, 3))
	TestUtils.expectValid(compiled, {})
	TestUtils.expectValid(compiled, { 20, 10 })
	TestUtils.expectValid(compiled, { 65535, 0, 1 })
	TestUtils.expectInvalid(compiled, { 1, 2, 3, 4 }, "SchemaArrayTooLong")
end)

type ArrayShapeCase = { name: string, value: any }
local invalidArrays: { ArrayShapeCase } = {
	{ name = "a missing first element", value = { [2] = 1 } },
	{ name = "an interior hole", value = { [1] = 1, [3] = 3 } },
	{ name = "a far-away element", value = { [1] = 1, [1000000] = 2 } },
	{ name = "a zero index", value = { [0] = 1 } },
	{ name = "a negative index", value = { [-1] = 1 } },
	{ name = "a fractional index", value = { [1.5] = 1 } },
	{ name = "a string key", value = { extra = 1 } },
	{ name = "mixed array and record keys", value = { [1] = 1, extra = 1 } },
}
for _, shapeCase: ArrayShapeCase in invalidArrays do
	it("Array rejects " .. shapeCase.name .. " independently of Luau's length operator", function()
		local compiled: CompiledSchema = TestUtils.compile(Schema.Array(Schema.U8, 3))
		TestUtils.expectInvalid(compiled, shapeCase.value, "SchemaArrayMustBeDense")
	end)
end

it("Array validates every element including the final element at the length bound", function()
	local compiled: CompiledSchema = TestUtils.compile(Schema.Array(Schema.U8, 3))
	TestUtils.expectInvalid(compiled, { 1, 2, 256 }, "SchemaIntegerOutOfRange")
	TestUtils.expectInvalid(compiled, { 1, false, 3 }, "SchemaValueTypeInvalid")
	TestUtils.expectInvalid(compiled, nil, "SchemaValueTypeInvalid")
	TestUtils.expectInvalid(compiled, "123", "SchemaValueTypeInvalid")
end)

it("Optional array elements do not make missing table indices into dense elements", function()
	local compiled: CompiledSchema = TestUtils.compile(Schema.Array(Schema.Optional(Schema.U8), 3))
	TestUtils.expectValid(compiled, {})
	TestUtils.expectValid(compiled, { 0, 1 })
	TestUtils.expectInvalid(compiled, { [1] = 1, [3] = 3 }, "SchemaArrayMustBeDense")
end)

it("Array preserves false-valued Boolean elements as dense entries", function()
	local compiled: CompiledSchema = TestUtils.compile(Schema.Array(Schema.Boolean, 3))
	TestUtils.expectValid(compiled, { false, true, false })
	TestUtils.expectInvalid(compiled, { false, true, false, true }, "SchemaArrayTooLong")
end)

it("Map accepts empty and maximum-entry unordered values including zero and negative integer keys", function()
	local compiled: CompiledSchema = TestUtils.compile(Schema.Map(Schema.I16, Schema.Boolean, 3))
	TestUtils.expectValid(compiled, {})
	TestUtils.expectValid(compiled, { [0] = false, [-1] = true, [32767] = false })
	TestUtils.expectInvalid(compiled, { [0] = false, [-1] = true, [2] = false, [3] = true }, "SchemaMapTooLarge")
end)

it("Map rejects invalid keys and values rather than coercing or skipping them", function()
	local compiled: CompiledSchema = TestUtils.compile(Schema.Map(Schema.Enum({ "Burn", "Slow" }), Schema.U8, 2))
	TestUtils.expectValid(compiled, { Burn = 1, Slow = 2 })
	TestUtils.expectInvalid(compiled, { Unknown = 1 }, "SchemaEnumValueInvalid")
	TestUtils.expectInvalid(compiled, { [1] = 1 }, "SchemaValueTypeInvalid")
	TestUtils.expectInvalid(compiled, { Burn = 256 }, "SchemaIntegerOutOfRange")
	TestUtils.expectInvalid(compiled, { Burn = false }, "SchemaValueTypeInvalid")
	TestUtils.expectInvalid(compiled, nil, "SchemaValueTypeInvalid")
	TestUtils.expectInvalid(compiled, true, "SchemaValueTypeInvalid")
end)

it("Map validates bounded String keys in bytes", function()
	local compiled: CompiledSchema = TestUtils.compile(Schema.Map(Schema.String(4), Schema.Boolean, 2))
	TestUtils.expectValid(compiled, { [""] = false, abcd = true })
	TestUtils.expectInvalid(compiled, { abcde = true }, "SchemaStringTooLong")
end)

it("Map enforces integer key ranges and integrality without coercing string keys", function()
	local compiled: CompiledSchema = TestUtils.compile(Schema.Map(Schema.U8, Schema.Boolean, 2))
	TestUtils.expectValid(compiled, { [0] = false, [255] = true })
	TestUtils.expectInvalid(compiled, { [-1] = true }, "SchemaIntegerOutOfRange")
	TestUtils.expectInvalid(compiled, { [256] = true }, "SchemaIntegerOutOfRange")
	TestUtils.expectInvalid(compiled, { [0.5] = true }, "SchemaIntegerMustBeIntegral")
	TestUtils.expectInvalid(compiled, { ["1"] = true }, "SchemaValueTypeInvalid")
	TestUtils.expectInvalid(compiled, { [{}] = true }, "SchemaValueTypeInvalid")
end)

it("Map validates nested Struct, Array, Optional, and Map state recursively", function()
	local compiled: CompiledSchema = TestUtils.compile(Schema.Map(
		Schema.String(8),
		Schema.Struct({
			stacks = Schema.U8,
			remaining = Schema.Optional(Schema.F32),
			sources = Schema.Array(Schema.Map(Schema.U16, Schema.Boolean, 2), 2),
		}),
		2
	))
	TestUtils.expectValid(compiled, { Burn = { stacks = 2, sources = { { [1] = true }, {} } } })
	TestUtils.expectInvalid(compiled, {
		Burn = { stacks = 2, sources = { { [65536] = true } } },
	}, "SchemaIntegerOutOfRange")
	TestUtils.expectInvalid(compiled, {
		Burn = { stacks = 2, sources = { { [1] = true, [2] = false, [3] = true } } },
	}, "SchemaMapTooLarge")
end)

it("validation preserves array order and leaves valid and invalid input tables untouched", function()
	local compiled: CompiledSchema = TestUtils.compile(Schema.Struct({
		values = Schema.Array(Schema.U8, 3),
		optional = Schema.Optional(Schema.Boolean),
	}))
	local validValue: any = { values = { 3, 1, 2 } }
	local invalidValue: any = { values = { 3, 256, 2 }, extra = false }
	TestUtils.expectValid(compiled, validValue)
	local accepted: boolean = Validator.Validate(compiled, invalidValue)
	expect(accepted).toBe(false)
	expect(validValue).toEqual({ values = { 3, 1, 2 } })
	expect(invalidValue).toEqual({ values = { 3, 256, 2 }, extra = false })
	expect(table.isfrozen(validValue)).toBe(false)
	expect(table.isfrozen(validValue.values)).toBe(false)
	expect(table.isfrozen(invalidValue)).toBe(false)
end)

it("validation of a frozen value needs no writes to the value or its children", function()
	local compiled: CompiledSchema = TestUtils.compile(Schema.Struct({ values = Schema.Array(Schema.U8, 3) }))
	local values: { number } = table.freeze({ 3, 1, 2 })
	local value: { read values: { number } } = table.freeze({ values = values })
	TestUtils.expectValid(compiled, value)
	expect(value.values).toEqual({ 3, 1, 2 })
end)
