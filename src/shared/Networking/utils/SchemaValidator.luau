--!strict
local NetworkingTypes = require(script.Parent.Parent.types)

type CompiledSchema = NetworkingTypes.CompiledSchema

local SchemaValidator = {} :: NetworkingTypes.SchemaValidator

function SchemaValidator.Validate(_schema: CompiledSchema, _value: any): (boolean, string?)
	-- TODO N1: validate values against the immutable compiled contract without mutation.
	return false, "SchemaValidationNotImplemented"
end

return SchemaValidator
