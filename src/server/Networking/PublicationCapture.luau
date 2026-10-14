--!strict
local PublicationTypes = require(script.Parent.PublicationTypes)
local SchemaTypes = require(script.Parent.Parent.Parent.shared.Networking.types)
local SchemaValidator = require(script.Parent.Parent.Parent.shared.Networking.utils.SchemaValidator)
local CodecCompiler = require(script.Parent.Parent.Parent.shared.Networking.CodecCompiler)

local PublicationCapture = {}
local CapturePlan = {}
CapturePlan.__index = CapturePlan

local function own(schema: SchemaTypes.CompiledSchema, value: any): any
	if value == nil then
		return nil
	end
	if schema.kind == "F32" then
		local bytes = buffer.create(4)
		buffer.writef32(bytes, 0, value)
		return buffer.readf32(bytes, 0)
	elseif schema.kind == "Optional" then
		return own(schema.inner, value)
	elseif schema.kind == "Struct" then
		local copied: { [string]: any } = {}
		for _, field in schema.fields do
			copied[field.name] = own(field.schema, value[field.name])
		end
		return table.freeze(copied)
	elseif schema.kind == "Array" then
		local copied: { any } = {}
		for index, item in value do
			copied[index] = own(schema.element, item)
		end
		return table.freeze(copied)
	elseif schema.kind == "Map" then
		local copied: { [any]: any } = {}
		for key, item in value do
			copied[key] = own(schema.value, item)
		end
		return table.freeze(copied)
	end
	return value
end

local function same(schema: SchemaTypes.CompiledSchema, first: any, second: any): boolean
	if first == second then
		return true
	end
	if first == nil or second == nil or type(first) ~= "table" or type(second) ~= "table" then
		return false
	end
	if schema.kind == "Optional" then
		return same(schema.inner, first, second)
	elseif schema.kind == "Struct" then
		for _, field in schema.fields do
			if not same(field.schema, first[field.name], second[field.name]) then
				return false
			end
		end
		return true
	elseif schema.kind == "Array" then
		if #first ~= #second then
			return false
		end
		for index, item in first do
			if not same(schema.element, item, second[index]) then
				return false
			end
		end
		return true
	elseif schema.kind == "Map" then
		for key, item in first do
			if second[key] == nil or not same(schema.value, item, second[key]) then
				return false
			end
		end
		for key in second do
			if first[key] == nil then
				return false
			end
		end
		return true
	end
	return false
end

local function diff(schema: SchemaTypes.CompiledSchema, value: any, previous: any): PublicationTypes.Patch?
	if same(schema, value, previous) then
		return nil
	end
	if schema.kind == "Struct" and previous ~= nil then
		local fields: { [string]: PublicationTypes.Patch } = {}
		for _, field in schema.fields do
			local patch = diff(field.schema, value[field.name], previous[field.name])
			if patch ~= nil then
				fields[field.name] = patch
			end
		end
		return table.freeze({ kind = "Struct", fields = table.freeze(fields) }) :: any
	elseif schema.kind == "Map" and previous ~= nil then
		local entries: { [any]: any } = {}
		local removed: { any } = {}
		for key, item in value do
			if previous[key] == nil or not same(schema.value, item, previous[key]) then
				entries[key] = item
			end
		end
		for key in previous do
			if value[key] == nil then
				table.insert(removed, key)
			end
		end
		table.sort(removed, function(a: any, b: any): boolean
			return a < b
		end)
		return table.freeze({ kind = "Map", entries = table.freeze(entries), removed = table.freeze(removed) }) :: any
	end
	return table.freeze({ kind = "Replace", value = value }) :: any
end

function PublicationCapture.Compile(schema: SchemaTypes.CompiledSchema): PublicationTypes.CapturePlan
	local codec: SchemaTypes.CompiledCodec?, reason: string? = CodecCompiler.Compile(schema)
	assert(codec ~= nil, reason or "CodecCompilationFailure")
	return setmetatable({ schema = schema, codec = codec }, CapturePlan) :: any
end

function CapturePlan.Capture(
	self: any,
	value: any,
	previous: PublicationTypes.CaptureResult?
): (PublicationTypes.CaptureResult?, string?)
	local valid: boolean, reason: string? = SchemaValidator.Validate(self.schema, value)
	if not valid then
		return nil, reason
	end
	local canonical = own(self.schema, value)
	local encodedSizeBytes: number?
	if self.codec.fixedSizeBytes ~= nil then
		encodedSizeBytes = self.codec.fixedSizeBytes
	else
		encodedSizeBytes, reason = self.codec.Measure(canonical)
	end
	if encodedSizeBytes == nil then
		return nil, reason
	end
	local patch = if previous == nil then nil else diff(self.schema, canonical, previous.value)
	return table.freeze({ value = canonical, patch = patch, encodedSizeBytes = encodedSizeBytes }) :: any, nil
end

return PublicationCapture
