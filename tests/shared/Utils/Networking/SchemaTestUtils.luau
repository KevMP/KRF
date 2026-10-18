--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF

local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local expect: any = JestGlobals.expect
local SharedNetworkingTypes = require(KRF.shared.Networking.types)
local Compiler: SharedNetworkingTypes.SchemaCompiler = require(KRF.shared.Networking.utils.SchemaCompiler)
local Validator: SharedNetworkingTypes.SchemaValidator = require(KRF.shared.Networking.utils.SchemaValidator)

local SchemaTestUtils = {}

function SchemaTestUtils.compile(
	definition: SharedNetworkingTypes.SchemaDefinition
): SharedNetworkingTypes.CompiledSchema
	local compiled: SharedNetworkingTypes.CompiledSchema?, reason: string? = Compiler.Compile(definition)
	expect(reason).toBeNil()
	expect(compiled).never.toBeNil()
	return compiled :: SharedNetworkingTypes.CompiledSchema
end

function SchemaTestUtils.expectValid(schema: SharedNetworkingTypes.CompiledSchema, value: any): ()
	local valid: boolean, reason: string? = Validator.Validate(schema, value)
	expect(valid).toBe(true)
	expect(reason).toBeNil()
end

function SchemaTestUtils.expectInvalid(
	schema: SharedNetworkingTypes.CompiledSchema,
	value: any,
	expectedReason: string
): ()
	local valid: boolean, reason: string? = Validator.Validate(schema, value)
	expect(valid).toBe(false)
	expect(reason).toBe(expectedReason)
end

return SchemaTestUtils
