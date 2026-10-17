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

local MAX_SAFE_INTEGER: number = 9007199254740991

type BoundsCase = { name: string, definition: SchemaDefinition }
local oversizedString: SchemaDefinition = Schema.String(MAX_SAFE_INTEGER)
local structFields: { [string]: SchemaDefinition } = { valid = Schema.U8, oversized = oversizedString }
local invalidSchemas: { BoundsCase } = {
	{ name = "String with no safe room for its length representation", definition = oversizedString },
	{ name = "Optional containing an oversized child", definition = Schema.Optional(oversizedString) },
	{ name = "Struct containing an oversized field", definition = Schema.Struct(structFields) },
	{ name = "Array containing an oversized element", definition = Schema.Array(oversizedString, 1) },
	{ name = "Map containing an oversized key", definition = Schema.Map(oversizedString, Schema.U8, 1) },
	{ name = "Map containing an oversized value", definition = Schema.Map(Schema.U8, oversizedString, 1) },
	{
		name = "Map whose individual key and value fit but their sum exceeds safe accounting",
		definition = Schema.Map(Schema.String(2 ^ 52), Schema.String(2 ^ 52), 1),
	},
	{
		name = "Array whose element bytes fit but leave no room for its length representation",
		definition = Schema.Array(Schema.U8, MAX_SAFE_INTEGER),
	},
	{
		name = "Map whose entry bytes fit but leave insufficient room for its length representation",
		definition = Schema.Map(Schema.U8, Schema.U8, (MAX_SAFE_INTEGER - 1) / 2),
	},
}

for _, boundsCase: BoundsCase in invalidSchemas do
	it("rejects a " .. boundsCase.name .. " without publishing partial compiled metadata", function()
		local compiled: CompiledSchema?, reason: string? = Compiler.Compile(boundsCase.definition)
		expect(compiled).toBeNil()
		expect(reason).toBe("SchemaEncodedSizeInvalid")
	end)
end

it("zero-byte Struct elements still produce a bounded Array without division by zero", function()
	local compiled: CompiledSchema = TestUtils.compile(Schema.Array(Schema.Struct({}), MAX_SAFE_INTEGER))
	expect(compiled.maxEncodedBytes > 0).toBe(true)
	expect(compiled.maxEncodedBytes <= MAX_SAFE_INTEGER).toBe(true)
	TestUtils.expectValid(compiled, {})
	TestUtils.expectValid(compiled, { {}, {} })
end)
