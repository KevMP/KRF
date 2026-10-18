--!strict
local Types = require(script.Parent.Parent.types)
local SchemaCollectionUtils = require(script.Parent.SchemaCollectionUtils)
local SchemaPrimitives = require(script.Parent.SchemaPrimitives)

type SchemaDefinition = Types.SchemaDefinition

type NormalizedNode = { definition: SchemaDefinition, height: number }

type NormalizationContext = {
	active: { [any]: boolean },
	completed: { [any]: NormalizedNode },
}

-- Private admission guard shared by constructors and the startup compiler.
local MAX_SCHEMA_DEPTH: number = 128

local mapKeyKinds: { [string]: boolean } = {
	String = true,
	Enum = true,
	U8 = true,
	U16 = true,
	U32 = true,
	I8 = true,
	I16 = true,
	I32 = true,
}

table.freeze(mapKeyKinds)

local fieldsByKind: { [string]: { [string]: boolean } } = {
	String = { kind = true, maxBytes = true },
	Enum = { kind = true, values = true },
	Optional = { kind = true, inner = true },
	Struct = { kind = true, fields = true },
	Array = { kind = true, element = true, maxLength = true },
	Map = { kind = true, key = true, value = true, maxEntries = true },
}

for kind: string in SchemaPrimitives do
	fieldsByKind[kind] = { kind = true }
end

for _, fields: { [string]: boolean } in fieldsByKind do
	table.freeze(fields)
end

table.freeze(fieldsByKind)

local function normalize(definition: any, depth: number, context: NormalizationContext): (NormalizedNode?, string?)
	if definition == nil then
		return nil, "SchemaDefinitionMissing"
	end

	if type(definition) ~= "table" then
		return nil, "SchemaDefinitionMustBeTable"
	end

	if context.active[definition] then
		return nil, "SchemaRecursiveDefinition"
	end

	if depth > MAX_SCHEMA_DEPTH then
		return nil, "SchemaDepthExceeded"
	end

	local completed: NormalizedNode? = context.completed[definition]

	if completed ~= nil then
		if depth + completed.height - 1 > MAX_SCHEMA_DEPTH then
			return nil, "SchemaDepthExceeded"
		end

		return completed, nil
	end

	context.active[definition] = true

	local kind: any = rawget(definition, "kind")
	local allowedFields: { [string]: boolean }? = if type(kind) == "string" then fieldsByKind[kind] else nil

	if allowedFields == nil then
		return nil, "SchemaKindInvalid"
	end

	for field in next, definition do
		if type(field) ~= "string" or not allowedFields[field] then
			return nil, "SchemaFieldUnknown"
		end
	end

	local owned: SchemaDefinition
	local height: number = 1

	if type(kind) == "string" and SchemaPrimitives[kind] ~= nil then
		owned = { kind = kind :: Types.PrimitiveKind }
	elseif kind == "String" then
		local maxBytes: any = rawget(definition, "maxBytes")

		if not SchemaCollectionUtils.IsPositiveInteger(maxBytes) then
			return nil, "SchemaStringMaxBytesInvalid"
		end

		owned = { kind = "String", maxBytes = maxBytes }
	elseif kind == "Enum" then
		local values: any = rawget(definition, "values")
		local count: number? = SchemaCollectionUtils.GetArrayLength(values)

		if count == nil then
			return nil, "SchemaEnumValuesMustBeArray"
		end

		if count == 0 then
			return nil, "SchemaEnumValuesCannotBeEmpty"
		end

		local copiedValues: { string } = {}
		local seenValues: { [string]: boolean } = {}

		for index: number = 1, count do
			local value: any = rawget(values, index)

			if type(value) ~= "string" or value == "" then
				return nil, "SchemaEnumValueInvalid"
			end

			if seenValues[value] then
				return nil, "SchemaEnumValueDuplicate"
			end

			seenValues[value] = true
			table.insert(copiedValues, value)
		end

		table.sort(copiedValues)
		owned = { kind = "Enum", values = table.freeze(copiedValues) }
	elseif kind == "Optional" then
		local inner: NormalizedNode?, reason: string? = normalize(rawget(definition, "inner"), depth + 1, context)

		if inner == nil then
			return nil, reason
		end

		owned = { kind = "Optional", inner = inner.definition }
		height += inner.height
	elseif kind == "Struct" then
		local fields: any = rawget(definition, "fields")

		if type(fields) ~= "table" then
			return nil, "SchemaStructFieldsMustBeTable"
		end

		local names: { string } = {}

		for name in next, fields do
			if type(name) ~= "string" or name == "" then
				return nil, "SchemaStructFieldNameInvalid"
			end

			table.insert(names, name)
		end

		table.sort(names)
		local copiedFields: { [string]: SchemaDefinition } = {}

		for _, name: string in names do
			local child: NormalizedNode?, reason: string? = normalize(rawget(fields, name), depth + 1, context)

			if child == nil then
				return nil, reason
			end

			copiedFields[name] = child.definition
			height = math.max(height, 1 + child.height)
		end

		owned = { kind = "Struct", fields = table.freeze(copiedFields) }
	elseif kind == "Array" then
		local maxLength: any = rawget(definition, "maxLength")

		if not SchemaCollectionUtils.IsPositiveInteger(maxLength) then
			return nil, "SchemaArrayMaxLengthInvalid"
		end

		local element: NormalizedNode?, reason: string? = normalize(rawget(definition, "element"), depth + 1, context)

		if element == nil then
			return nil, reason
		end

		owned = { kind = "Array", element = element.definition, maxLength = maxLength }
		height += element.height
	elseif kind == "Map" then
		local maxEntries: any = rawget(definition, "maxEntries")

		if not SchemaCollectionUtils.IsPositiveInteger(maxEntries) then
			return nil, "SchemaMapMaxEntriesInvalid"
		end

		local key: NormalizedNode?, keyReason: string? = normalize(rawget(definition, "key"), depth + 1, context)

		if key == nil then
			return nil, keyReason
		end

		if not mapKeyKinds[key.definition.kind] then
			return nil, "SchemaMapKeyUnsupported"
		end

		local value: NormalizedNode?, valueReason: string? = normalize(rawget(definition, "value"), depth + 1, context)

		if value == nil then
			return nil, valueReason
		end

		owned = { kind = "Map", key = key.definition, value = value.definition, maxEntries = maxEntries }
		height += math.max(key.height, value.height)
	else
		return nil, "SchemaKindInvalid"
	end

	local node: NormalizedNode = { definition = table.freeze(owned), height = height }

	context.active[definition] = nil
	context.completed[definition] = node

	return node, nil
end

local SchemaDefinitionNormalizer = {}

function SchemaDefinitionNormalizer.Normalize(definition: SchemaDefinition): (SchemaDefinition?, string?)
	local context: NormalizationContext = { active = {}, completed = {} }
	local node: NormalizedNode?, reason: string? = normalize(definition, 1, context)

	return if node ~= nil then node.definition else nil, reason
end

return SchemaDefinitionNormalizer
