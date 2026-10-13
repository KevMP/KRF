--!strict
local NetworkingTypes = require(script.Parent.Parent.types)

local SchemaProjection = {}

function SchemaProjection.Definition(schema: NetworkingTypes.CompiledSchema): NetworkingTypes.SchemaDefinition
	local definition: NetworkingTypes.SchemaDefinition
	if schema.kind == "String" then
		definition = { kind = "String", maxBytes = schema.maxBytes }
	elseif schema.kind == "Enum" then
		definition = { kind = "Enum", values = schema.values }
	elseif schema.kind == "Optional" then
		definition = { kind = "Optional", inner = SchemaProjection.Definition(schema.inner) }
	elseif schema.kind == "Array" then
		definition =
			{ kind = "Array", element = SchemaProjection.Definition(schema.element), maxLength = schema.maxLength }
	elseif schema.kind == "Map" then
		definition = {
			kind = "Map",
			key = SchemaProjection.Definition(schema.key),
			value = SchemaProjection.Definition(schema.value),
			maxEntries = schema.maxEntries,
		}
	elseif schema.kind == "Struct" then
		local fields: { [string]: NetworkingTypes.SchemaDefinition } = {}
		for _, field: NetworkingTypes.CompiledField in schema.fields do
			fields[field.name] = SchemaProjection.Definition(field.schema)
		end
		table.freeze(fields)
		definition = { kind = "Struct", fields = fields }
	else
		definition = { kind = schema.kind }
	end
	table.freeze(definition)
	return definition
end

return SchemaProjection
