--!strict
local Types = require(script.Parent.Parent.types)
local SchemaDefinitionNormalizer = require(script.Parent.SchemaDefinitionNormalizer)
local SchemaPrimitives = require(script.Parent.SchemaPrimitives)

type SchemaDefinition = Types.SchemaDefinition
type CompiledSchema = Types.CompiledSchema

local SchemaCompiler = {} :: Types.SchemaCompiler

local MAX_SAFE_INTEGER: number = 9007199254740991
-- Conservative allowance for a future length or enum ordinal representation.
-- N2 may narrow this overhead; consumers cannot rely on byte offsets or packing.
local COLLECTION_PREFIX_MAX_BYTES: number = 8

local function addBytes(first: number, second: number): number?
	if first > MAX_SAFE_INTEGER - second then
		return nil
	end

	return first + second
end

local function multiplyBytes(bytes: number, count: number): number?
	if bytes ~= 0 and count > math.floor(MAX_SAFE_INTEGER / bytes) then
		return nil
	end

	return bytes * count
end

local function compile(
	definition: SchemaDefinition,
	completed: { [SchemaDefinition]: CompiledSchema }
): (CompiledSchema?, string?)
	local cached: CompiledSchema? = completed[definition]

	if cached ~= nil then
		return cached, nil
	end

	local owned: CompiledSchema
	local primitive: SchemaPrimitives.PrimitiveContract? = SchemaPrimitives[definition.kind]

	if primitive ~= nil then
		owned = { kind = definition.kind :: Types.PrimitiveKind, maxEncodedBytes = primitive.maxEncodedBytes }
	elseif definition.kind == "String" then
		local maximum: number? = addBytes(COLLECTION_PREFIX_MAX_BYTES, definition.maxBytes)

		if maximum == nil then
			return nil, "SchemaEncodedSizeInvalid"
		end

		owned = { kind = "String", maxBytes = definition.maxBytes, maxEncodedBytes = maximum }
	elseif definition.kind == "Enum" then
		local ordinalsByValue: { [string]: number } = {}

		for index: number, value: string in definition.values do
			ordinalsByValue[value] = index - 1
		end

		owned = {
			kind = "Enum",
			values = definition.values,
			ordinalsByValue = table.freeze(ordinalsByValue),
			maxEncodedBytes = COLLECTION_PREFIX_MAX_BYTES,
		}
	elseif definition.kind == "Optional" then
		local inner: CompiledSchema?, reason: string? = compile(definition.inner, completed)

		if inner == nil then
			return nil, reason
		end

		local maximum: number? = addBytes(1, inner.maxEncodedBytes)

		if maximum == nil then
			return nil, "SchemaEncodedSizeInvalid"
		end

		owned = { kind = "Optional", inner = inner, maxEncodedBytes = maximum }
	elseif definition.kind == "Struct" then
		local names: { string } = {}

		for name: string in definition.fields do
			table.insert(names, name)
		end

		table.sort(names)
		local fields: { Types.CompiledField } = {}
		local fieldsByName: { [string]: CompiledSchema } = {}
		local maximum: number = 0

		for _, name: string in names do
			local child: CompiledSchema?, reason: string? = compile(definition.fields[name], completed)

			if child == nil then
				return nil, reason
			end

			local total: number? = addBytes(maximum, child.maxEncodedBytes)

			if total == nil then
				return nil, "SchemaEncodedSizeInvalid"
			end

			maximum = total
			local field: Types.CompiledField = { name = name, schema = child }
			table.freeze(field)
			table.insert(fields, field)
			fieldsByName[name] = child
		end

		owned = {
			kind = "Struct",
			fields = table.freeze(fields),
			fieldsByName = table.freeze(fieldsByName),
			maxEncodedBytes = maximum,
		}
	elseif definition.kind == "Array" then
		local element: CompiledSchema?, reason: string? = compile(definition.element, completed)

		if element == nil then
			return nil, reason
		end

		local entriesMaximum: number? = multiplyBytes(element.maxEncodedBytes, definition.maxLength)

		local maximum: number? = if entriesMaximum ~= nil
			then addBytes(COLLECTION_PREFIX_MAX_BYTES, entriesMaximum)
			else nil

		if maximum == nil then
			return nil, "SchemaEncodedSizeInvalid"
		end

		owned = { kind = "Array", element = element, maxLength = definition.maxLength, maxEncodedBytes = maximum }
	elseif definition.kind == "Map" then
		local key: CompiledSchema?, keyReason: string? = compile(definition.key, completed)

		if key == nil then
			return nil, keyReason
		end

		local value: CompiledSchema?, valueReason: string? = compile(definition.value, completed)

		if value == nil then
			return nil, valueReason
		end

		local entryMaximum: number? = addBytes(key.maxEncodedBytes, value.maxEncodedBytes)

		local entriesMaximum: number? = if entryMaximum ~= nil
			then multiplyBytes(entryMaximum, definition.maxEntries)
			else nil

		local maximum: number? = if entriesMaximum ~= nil
			then addBytes(COLLECTION_PREFIX_MAX_BYTES, entriesMaximum)
			else nil

		if maximum == nil then
			return nil, "SchemaEncodedSizeInvalid"
		end

		owned =
			{ kind = "Map", key = key, value = value, maxEntries = definition.maxEntries, maxEncodedBytes = maximum }
	else
		error("Schema compiler received an unnormalized definition", 2)
	end

	table.freeze(owned)
	completed[definition] = owned

	return owned, nil
end

function SchemaCompiler.Compile(definition: SchemaDefinition): (CompiledSchema?, string?)
	local normalized: SchemaDefinition?, reason: string? = SchemaDefinitionNormalizer.Normalize(definition)

	if normalized == nil then
		return nil, reason
	end

	return compile(normalized, {})
end

return SchemaCompiler
