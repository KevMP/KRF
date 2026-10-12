--!strict
local NetworkingTypes = require(script.Parent.types)
local SchemaDefinitionNormalizer = require(script.Parent.utils.SchemaDefinitionNormalizer)

export type SchemaDefinition = NetworkingTypes.SchemaDefinition
type Schema = NetworkingTypes.Schema

local function construct(definition: SchemaDefinition): SchemaDefinition
	local owned: SchemaDefinition?, reason: string? = SchemaDefinitionNormalizer.Normalize(definition)
	if owned == nil then
		error(reason :: string, 3)
	end
	return owned
end

local Schema: Schema = {
	Boolean = construct({ kind = "Boolean" }),
	U8 = construct({ kind = "U8" }),
	U16 = construct({ kind = "U16" }),
	U32 = construct({ kind = "U32" }),
	I8 = construct({ kind = "I8" }),
	I16 = construct({ kind = "I16" }),
	I32 = construct({ kind = "I32" }),
	F32 = construct({ kind = "F32" }),
	F64 = construct({ kind = "F64" }),
	String = function(maxBytes: number): SchemaDefinition
		return construct({ kind = "String", maxBytes = maxBytes })
	end,
	Enum = function(values: { string }): SchemaDefinition
		return construct({ kind = "Enum", values = values })
	end,
	Optional = function(inner: SchemaDefinition): SchemaDefinition
		return construct({ kind = "Optional", inner = inner })
	end,
	Struct = function(fields: { [string]: SchemaDefinition }): SchemaDefinition
		return construct({ kind = "Struct", fields = fields })
	end,
	Array = function(element: SchemaDefinition, maxLength: number): SchemaDefinition
		return construct({ kind = "Array", element = element, maxLength = maxLength })
	end,
	Map = function(key: SchemaDefinition, value: SchemaDefinition, maxEntries: number): SchemaDefinition
		return construct({ kind = "Map", key = key, value = value, maxEntries = maxEntries })
	end,
}

return table.freeze(Schema)
