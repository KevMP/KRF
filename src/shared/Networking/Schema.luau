--!strict
local NetworkingTypes = require(script.Parent.types)

export type SchemaDefinition = NetworkingTypes.SchemaDefinition
type Schema = NetworkingTypes.Schema

-- N1 TDD scaffold: descriptors only. Constructor validation and recursive
-- ownership/immutability are intentionally left for the implementation step.
local Schema: Schema = {
	Boolean = { kind = "Boolean" },
	U8 = { kind = "U8" },
	U16 = { kind = "U16" },
	U32 = { kind = "U32" },
	I8 = { kind = "I8" },
	I16 = { kind = "I16" },
	I32 = { kind = "I32" },
	F32 = { kind = "F32" },
	F64 = { kind = "F64" },
	String = function(maxBytes: number): SchemaDefinition
		return { kind = "String", maxBytes = maxBytes }
	end,
	Enum = function(values: { string }): SchemaDefinition
		return { kind = "Enum", values = values }
	end,
	Optional = function(inner: SchemaDefinition): SchemaDefinition
		return { kind = "Optional", inner = inner }
	end,
	Struct = function(fields: { [string]: SchemaDefinition }): SchemaDefinition
		return { kind = "Struct", fields = fields }
	end,
	Array = function(element: SchemaDefinition, maxLength: number): SchemaDefinition
		return { kind = "Array", element = element, maxLength = maxLength }
	end,
	Map = function(key: SchemaDefinition, value: SchemaDefinition, maxEntries: number): SchemaDefinition
		return { kind = "Map", key = key, value = value, maxEntries = maxEntries }
	end,
}

return Schema
