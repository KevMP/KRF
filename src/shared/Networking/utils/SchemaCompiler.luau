--!strict
local NetworkingTypes = require(script.Parent.Parent.types)

type SchemaDefinition = NetworkingTypes.SchemaDefinition
type CompiledSchema = NetworkingTypes.CompiledSchema

local SchemaCompiler = {} :: NetworkingTypes.SchemaCompiler

function SchemaCompiler.Compile(_definition: SchemaDefinition): (CompiledSchema?, string?)
	-- TODO N1: recursively validate, normalize, own, freeze, and derive finite bounds.
	return nil, "SchemaNotImplemented"
end

return SchemaCompiler
