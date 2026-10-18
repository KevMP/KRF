--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF

local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local SharedNetworkingTypes = require(KRF.shared.Networking.types)
local Schema: SharedNetworkingTypes.Schema = require(KRF.shared.Networking.Schema)
local TestUtils = require(script.Parent.Parent.Utils.Networking.SchemaTestUtils)

type SchemaDefinition = SharedNetworkingTypes.SchemaDefinition
type CompiledSchema = SharedNetworkingTypes.CompiledSchema

it("exposes explicit numeric representations and no unrestricted schema vocabulary", function()
	local primitives: { SchemaDefinition } = {
		Schema.Boolean,
		Schema.U8,
		Schema.U16,
		Schema.U32,
		Schema.I8,
		Schema.I16,
		Schema.I32,
		Schema.F32,
		Schema.F64,
	}
	local kinds: { string } = { "Boolean", "U8", "U16", "U32", "I8", "I16", "I32", "F32", "F64" }
	for index: number, definition: SchemaDefinition in primitives do
		expect(definition.kind).toBe(kinds[index])
		expect(table.isfrozen(definition)).toBe(true)
	end
	expect((Schema :: any).Any).toBeNil()
	expect((Schema :: any).Table).toBeNil()
	expect((Schema :: any).Dictionary).toBeNil()
	expect((Schema :: any).Number).toBeNil()
end)

type BoundCase = { name: string, value: any }
local invalidBounds: { BoundCase } = {
	{ name = "missing", value = nil },
	{ name = "zero", value = 0 },
	{ name = "negative", value = -1 },
	{ name = "fractional", value = 1.5 },
	{ name = "string", value = "8" },
	{ name = "boolean", value = true },
	{ name = "NaN", value = 0 / 0 },
	{ name = "infinite", value = math.huge },
	{ name = "negative infinity", value = -math.huge },
}

for _, boundCase: BoundCase in invalidBounds do
	it("String rejects a " .. boundCase.name .. " byte bound at construction", function()
		expect(function()
			Schema.String(boundCase.value)
		end).toThrow("SchemaStringMaxBytesInvalid")
	end)
	it("Array rejects a " .. boundCase.name .. " length bound at construction", function()
		expect(function()
			Schema.Array(Schema.U8, boundCase.value)
		end).toThrow("SchemaArrayMaxLengthInvalid")
	end)
	it("Map rejects a " .. boundCase.name .. " entry bound at construction", function()
		expect(function()
			Schema.Map(Schema.U8, Schema.Boolean, boundCase.value)
		end).toThrow("SchemaMapMaxEntriesInvalid")
	end)
end

it("copies enum source membership before the caller changes its array", function()
	local sourceValues: { string } = { "Idle", "Blocking" }
	local definition: SchemaDefinition = Schema.Enum(sourceValues)
	sourceValues[1] = "Flying"
	table.insert(sourceValues, "Stunned")
	local compiled: CompiledSchema = TestUtils.compile(definition)
	TestUtils.expectValid(compiled, "Idle")
	TestUtils.expectValid(compiled, "Blocking")
	TestUtils.expectInvalid(compiled, "Flying", "SchemaEnumValueInvalid")
	TestUtils.expectInvalid(compiled, "Stunned", "SchemaEnumValueInvalid")
	expect(table.isfrozen(sourceValues)).toBe(false)
end)

it("copies Struct source fields before the caller replaces or adds fields", function()
	local sourceFields: { [string]: SchemaDefinition } = { guard = Schema.F32 }
	local definition: SchemaDefinition = Schema.Struct(sourceFields)
	sourceFields.guard = Schema.Boolean
	sourceFields.injected = Schema.U8
	local compiled: CompiledSchema = TestUtils.compile(definition)
	TestUtils.expectValid(compiled, { guard = 20 })
	TestUtils.expectInvalid(compiled, { guard = false }, "SchemaValueTypeInvalid")
	TestUtils.expectInvalid(compiled, { guard = 20, injected = 1 }, "SchemaStructFieldUndeclared")
	expect(table.isfrozen(sourceFields)).toBe(false)
end)

it("constructs immutable descriptors for every bounded composite form", function()
	local definitions: { SchemaDefinition } = {
		Schema.String(8),
		Schema.Enum({ "Idle" }),
		Schema.Optional(Schema.U8),
		Schema.Struct({ active = Schema.Boolean }),
		Schema.Array(Schema.U8, 4),
		Schema.Map(Schema.String(8), Schema.F32, 4),
	}
	for _, definition: SchemaDefinition in definitions do
		expect(table.isfrozen(definition)).toBe(true)
		if definition.kind == "Enum" then
			expect(table.isfrozen(definition.values)).toBe(true)
		elseif definition.kind == "Struct" then
			expect(table.isfrozen(definition.fields)).toBe(true)
			expect(table.isfrozen(definition.fields.active)).toBe(true)
		elseif definition.kind == "Optional" then
			expect(table.isfrozen(definition.inner)).toBe(true)
		elseif definition.kind == "Array" then
			expect(table.isfrozen(definition.element)).toBe(true)
		elseif definition.kind == "Map" then
			expect(table.isfrozen(definition.key)).toBe(true)
			expect(table.isfrozen(definition.value)).toBe(true)
		end
	end
end)
