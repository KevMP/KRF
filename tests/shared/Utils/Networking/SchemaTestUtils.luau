--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF

local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local expect: any = JestGlobals.expect
local NetworkingTypes = require(KRF.shared.Networking.types)
local Compiler: NetworkingTypes.SchemaCompiler = require(KRF.shared.Networking.utils.SchemaCompiler)
local Validator: NetworkingTypes.SchemaValidator = require(KRF.shared.Networking.utils.SchemaValidator)

local SchemaTestUtils = {}

function SchemaTestUtils.compile(definition: NetworkingTypes.SchemaDefinition): NetworkingTypes.CompiledSchema
	local compiled: NetworkingTypes.CompiledSchema?, reason: string? = Compiler.Compile(definition)
	expect(reason).toBeNil()
	expect(compiled).never.toBeNil()
	return compiled :: NetworkingTypes.CompiledSchema
end

function SchemaTestUtils.expectValid(schema: NetworkingTypes.CompiledSchema, value: any): ()
	local valid: boolean, reason: string? = Validator.Validate(schema, value)
	expect(valid).toBe(true)
	expect(reason).toBeNil()
end

function SchemaTestUtils.expectInvalid(schema: NetworkingTypes.CompiledSchema, value: any, expectedReason: string): ()
	local valid: boolean, reason: string? = Validator.Validate(schema, value)
	expect(valid).toBe(false)
	expect(reason).toBe(expectedReason)
end

return SchemaTestUtils
