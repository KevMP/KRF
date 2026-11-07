--!strict
local Types = require(script.Parent.Parent.types)
local NetworkingTypes = require(script.Parent.Parent.Parent.Networking.types)

-- Bump when the canonical serialization changes so stale peers never share a tag.
local CANONICAL_VERSION: string = "KRF.ActionRequest/1"
local FNV_OFFSET_BASIS: number = 2166136261
local U32_MODULUS: number = 4294967296

local function lengthPrefixed(value: string): string
	return #value .. ":" .. value
end

-- Struct fields are already sorted by the schema compiler, so authoring order never leaks.
local function canonical(schema: NetworkingTypes.CompiledSchema): string
	if schema.kind == "String" then
		return "String(" .. schema.maxBytes .. ")"
	elseif schema.kind == "Enum" then
		local parts: { string } = {}

		for _, value: string in schema.values do
			table.insert(parts, lengthPrefixed(value))
		end

		return "Enum[" .. table.concat(parts, ",") .. "]"
	elseif schema.kind == "Optional" then
		return "Optional(" .. canonical(schema.inner) .. ")"
	elseif schema.kind == "Struct" then
		local parts: { string } = {}

		for _, field: NetworkingTypes.CompiledField in schema.fields do
			table.insert(parts, lengthPrefixed(field.name) .. "=" .. canonical(field.schema))
		end

		return "Struct{" .. table.concat(parts, ";") .. "}"
	elseif schema.kind == "Array" then
		return "Array(" .. canonical(schema.element) .. "," .. schema.maxLength .. ")"
	elseif schema.kind == "Map" then
		return "Map(" .. canonical(schema.key) .. "," .. canonical(schema.value) .. "," .. schema.maxEntries .. ")"
	end

	return schema.kind
end

local function optional(schema: NetworkingTypes.CompiledSchema?): string
	return if schema ~= nil then "(" .. canonical(schema) .. ")" else "-"
end

-- FNV-1a over the canonical bytes. The prime multiply is decomposed into shifts so
-- every intermediate stays exact inside a double.
local function hash(source: string): number
	local value: number = FNV_OFFSET_BASIS

	for index: number = 1, #source do
		value = bit32.bxor(value, string.byte(source, index))

		value = (
			value
			+ bit32.lshift(value, 1)
			+ bit32.lshift(value, 4)
			+ bit32.lshift(value, 7)
			+ bit32.lshift(value, 8)
			+ bit32.lshift(value, 24)
		) % U32_MODULUS
	end

	return value
end

local ActionContractTag: Types.ActionContractTagModule = table.freeze({
	Compute = function(
		actionId: string,
		start: NetworkingTypes.CompiledSchema?,
		stop: Types.CompiledActionPayload?,
		allowInputInterrupt: boolean,
		requiresClientRelease: boolean,
		onDisconnect: Types.ActionDisconnectPolicy
	): number
		local stopPart: string = if stop ~= nil then "P" .. optional(stop.schema) else "-"

		return hash(table.concat({
			CANONICAL_VERSION,
			lengthPrefixed(actionId),
			"S" .. optional(start),
			"T" .. stopPart,
			"I" .. (if allowInputInterrupt then "1" else "0"),
			"R" .. (if requiresClientRelease then "1" else "0"),
			"D" .. onDisconnect,
		}, "|"))
	end,
})

return ActionContractTag
