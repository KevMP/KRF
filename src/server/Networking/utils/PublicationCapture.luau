--!strict
local Types = require(script.Parent.Parent.types)
local SharedNetworkingTypes = require(script.Parent.Parent.Parent.Parent.shared.Networking.types)
local SchemaValidator = require(script.Parent.Parent.Parent.Parent.shared.Networking.utils.SchemaValidator)
local SchemaCollectionUtils = require(script.Parent.Parent.Parent.Parent.shared.Networking.utils.SchemaCollectionUtils)
local CodecCompiler = require(script.Parent.Parent.Parent.Parent.shared.Networking.CodecCompiler)

local PublicationCapture = {}

local CapturePlan = {}
CapturePlan.__index = CapturePlan

type CaptureNode = (value: any, previous: any, hadPrevious: boolean) -> (any, Types.PublicationPatch?, string?)

local function replacement(value: any): Types.PublicationPatch
	return table.freeze({ kind = "Replace", value = value }) :: any
end

local function compileNode(schema: SharedNetworkingTypes.CompiledSchema): CaptureNode
	if schema.kind == "Optional" then
		local inner = compileNode(schema.inner)

		return function(value: any, previous: any, hadPrevious: boolean): (any, Types.PublicationPatch?, string?)
			if value == nil then
				return nil, if hadPrevious and previous ~= nil then replacement(nil) else nil, nil
			end

			return inner(value, previous, hadPrevious)
		end
	elseif schema.kind == "Struct" then
		local fields: { { name: string, node: CaptureNode, optional: boolean } } = {}

		for _, field in schema.fields do
			table.insert(fields, {
				name = field.name,
				node = compileNode(field.schema),
				optional = field.schema.kind == "Optional",
			})
		end

		return function(value: any, previous: any, hadPrevious: boolean): (any, Types.PublicationPatch?, string?)
			if type(value) ~= "table" then
				return nil, nil, "SchemaValueTypeInvalid"
			end

			for name in next, value do
				if type(name) ~= "string" or schema.fieldsByName[name] == nil then
					return nil, nil, "SchemaStructFieldUndeclared"
				end
			end

			local canonical: { [string]: any } = {}
			local changedFields: { [string]: Types.PublicationPatch } = {}
			local canDiffFields = hadPrevious and previous ~= nil

			for _, field in fields do
				local item = rawget(value, field.name)

				if item == nil and not field.optional then
					return nil, nil, "SchemaStructFieldMissing"
				end

				local prior = if canDiffFields then previous[field.name] else nil
				local owned, patch, reason = field.node(item, prior, canDiffFields)

				if reason ~= nil then
					return nil, nil, reason
				end

				canonical[field.name] = owned

				if patch ~= nil then
					changedFields[field.name] = patch
				end
			end

			table.freeze(canonical)

			if not hadPrevious then
				return canonical, nil, nil
			elseif not canDiffFields then
				return canonical, replacement(canonical), nil
			elseif next(changedFields) ~= nil then
				return canonical, table.freeze({ kind = "Struct", fields = table.freeze(changedFields) }) :: any, nil
			end

			return canonical, nil, nil
		end
	elseif schema.kind == "Array" then
		local element = compileNode(schema.element)

		return function(value: any, previous: any, hadPrevious: boolean): (any, Types.PublicationPatch?, string?)
			if type(value) ~= "table" then
				return nil, nil, "SchemaValueTypeInvalid"
			end

			local length = SchemaCollectionUtils.GetArrayLength(value)

			if length == nil then
				return nil, nil, "SchemaArrayMustBeDense"
			elseif length > schema.maxLength then
				return nil, nil, "SchemaArrayTooLong"
			end

			local canonical: { any } = {}
			local canCompare = hadPrevious and previous ~= nil
			local changed = canCompare and length ~= #previous

			for index = 1, length do
				local owned, patch, reason =
					element(rawget(value, index), if canCompare then previous[index] else nil, canCompare)

				if reason ~= nil then
					return nil, nil, reason
				end

				canonical[index] = owned

				if patch ~= nil then
					changed = true
				end
			end

			table.freeze(canonical)

			return canonical, if hadPrevious and (not canCompare or changed) then replacement(canonical) else nil, nil
		end
	elseif schema.kind == "Map" then
		local entry = compileNode(schema.value)

		return function(value: any, previous: any, hadPrevious: boolean): (any, Types.PublicationPatch?, string?)
			if type(value) ~= "table" then
				return nil, nil, "SchemaValueTypeInvalid"
			end

			local canonical: { [any]: any } = {}
			local entries: { [any]: any } = {}
			local removed: { any } = {}
			local canDiffEntries = hadPrevious and previous ~= nil
			local count = 0

			for key, item in next, value do
				count += 1

				if count > schema.maxEntries then
					return nil, nil, "SchemaMapTooLarge"
				end

				local keyValid, keyReason = SchemaValidator.Validate(schema.key, key)

				if not keyValid then
					return nil, nil, keyReason
				end

				local prior = if canDiffEntries then previous[key] else nil
				local existed = canDiffEntries and prior ~= nil
				local owned, patch, reason = entry(item, prior, existed)

				if reason ~= nil then
					return nil, nil, reason
				end

				canonical[key] = owned

				if canDiffEntries and (not existed or patch ~= nil) then
					entries[key] = owned
				end
			end

			if canDiffEntries then
				for key in previous do
					if value[key] == nil then
						table.insert(removed, key)
					end
				end

				table.sort(removed)
			end

			table.freeze(canonical)

			if not hadPrevious then
				return canonical, nil, nil
			elseif not canDiffEntries then
				return canonical, replacement(canonical), nil
			elseif next(entries) ~= nil or #removed > 0 then
				return canonical,
					table.freeze({
						kind = "Map",
						entries = table.freeze(entries),
						removed = table.freeze(removed),
					}) :: any,
					nil
			end

			return canonical, nil, nil
		end
	end

	return function(value: any, previous: any, hadPrevious: boolean): (any, Types.PublicationPatch?, string?)
		local valid, reason = SchemaValidator.Validate(schema, value)

		if not valid then
			return nil, nil, reason
		end

		local canonical = value

		if schema.kind == "F32" then
			local bytes = buffer.create(4)
			buffer.writef32(bytes, 0, value)
			canonical = buffer.readf32(bytes, 0)
		end

		return canonical, if hadPrevious and canonical ~= previous then replacement(canonical) else nil, nil
	end
end

function PublicationCapture.Compile(schema: SharedNetworkingTypes.CompiledSchema): Types.PublicationCapturePlan
	local codec: SharedNetworkingTypes.CompiledCodec?, reason: string? = CodecCompiler.Compile(schema)
	assert(codec ~= nil, reason or "CodecCompilationFailure")

	return setmetatable({ capture = compileNode(schema), codec = codec }, CapturePlan) :: any
end

function CapturePlan.Capture(
	self: any,
	value: any,
	previous: Types.PublicationCaptureResult?
): (Types.PublicationCaptureResult?, string?)
	local canonical, patch, reason =
		self.capture(value, if previous ~= nil then previous.value else nil, previous ~= nil)

	if reason ~= nil then
		return nil, reason
	end

	local encodedSizeBytes: number?

	if self.codec.fixedSizeBytes ~= nil then
		encodedSizeBytes = self.codec.fixedSizeBytes
	else
		encodedSizeBytes, reason = self.codec.Measure(canonical)
	end

	if encodedSizeBytes == nil then
		return nil, reason
	end

	return table.freeze({ value = canonical, patch = patch, encodedSizeBytes = encodedSizeBytes }) :: any, nil
end

return PublicationCapture
