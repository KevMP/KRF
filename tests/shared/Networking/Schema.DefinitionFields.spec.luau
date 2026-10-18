--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF

local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local SharedNetworkingTypes = require(KRF.shared.Networking.types)
local Schema: SharedNetworkingTypes.Schema = require(KRF.shared.Networking.Schema)
local Compiler: SharedNetworkingTypes.SchemaCompiler = require(KRF.shared.Networking.utils.SchemaCompiler)
local TestUtils = require(script.Parent.Parent.Utils.Networking.SchemaTestUtils)

type SchemaDefinition = SharedNetworkingTypes.SchemaDefinition
type CompiledSchema = SharedNetworkingTypes.CompiledSchema

local function expectUnknownField(definition: any): ()
	local compiled: CompiledSchema?, reason: string? = Compiler.Compile(definition)
	expect(compiled).toBeNil()
	expect(reason).toBe("SchemaFieldUnknown")
end

local definitions: { SchemaDefinition } = {
	Schema.Boolean,
	Schema.U8,
	Schema.U16,
	Schema.U32,
	Schema.I8,
	Schema.I16,
	Schema.I32,
	Schema.F32,
	Schema.F64,
	Schema.String(8),
	Schema.Enum({ "Idle" }),
	Schema.Optional(Schema.U8),
	Schema.Struct({ count = Schema.U8 }),
	Schema.Array(Schema.U8, 2),
	Schema.Map(Schema.U8, Schema.U8, 2),
}

for _, definition: SchemaDefinition in definitions do
	it(definition.kind .. " accepts declared fields and rejects unknown, foreign-kind, and numeric fields", function()
		TestUtils.compile(definition)

		local unknown: any = table.clone(definition)
		unknown.somethingKRFDoesNotUnderstand = false
		expectUnknownField(unknown)

		local foreign: any = table.clone(definition)
		foreign[if definition.kind == "Map" then "element" else "value"] = Schema.U8
		expectUnknownField(foreign)

		local numeric: any = table.clone(definition)
		numeric[1] = true
		expectUnknownField(numeric)
	end)
end

local invalidChild: SchemaDefinition = { kind = "U8" }
(invalidChild :: any).futureSemantics = true

local nestedFields: { [string]: SchemaDefinition } = { child = invalidChild }

local nestedDefinitions: { SchemaDefinition } = {
	{ kind = "Optional", inner = invalidChild },
	{ kind = "Struct", fields = nestedFields },
	{ kind = "Array", element = invalidChild, maxLength = 2 },
	{ kind = "Map", key = invalidChild, value = Schema.U8, maxEntries = 2 },
	{ kind = "Map", key = Schema.U8, value = invalidChild, maxEntries = 2 },
}

for index: number, definition: SchemaDefinition in nestedDefinitions do
	it("rejects unknown nested schema fields in " .. definition.kind .. " case " .. tostring(index), function()
		expectUnknownField(definition)
	end)
end

it("friendly constructors reject unknown fields in supplied child schemas rather than discarding them", function()
	expect(function()
		Schema.Optional(invalidChild)
	end).toThrow("SchemaFieldUnknown")

	expect(function()
		Schema.Struct({ child = invalidChild })
	end).toThrow("SchemaFieldUnknown")

	expect(function()
		Schema.Array(invalidChild, 2)
	end).toThrow("SchemaFieldUnknown")

	expect(function()
		Schema.Map(invalidChild, Schema.U8, 2)
	end).toThrow("SchemaFieldUnknown")

	expect(function()
		Schema.Map(Schema.U8, invalidChild, 2)
	end).toThrow("SchemaFieldUnknown")
end)
