--!strict
local Types = require(script.Parent.Parent.types)
local Constants = require(script.Parent.CommandConstants)
local Collections = require(script.Parent.SchemaCollectionUtils)
local BufferUtils = require(script.Parent.CodecBufferUtils)
local SchemaCompiler = require(script.Parent.SchemaCompiler)
local CodecCompiler = require(script.Parent.Parent.CodecCompiler)

local CommandManifest = {}

function CommandManifest.Compile(
	definitions: { Types.ManifestCommand }?
): ({ [string]: Types.ClientCommand }?, { [number]: Types.ClientCommand }?, string?)
	local raw: any = if definitions ~= nil then definitions else {}
	local count: number? = if type(raw) == "table" then Collections.GetArrayLength(raw) else nil

	if count == nil or count > Constants.MAX_COMMANDS then
		return nil, nil, "MalformedBootstrap"
	end

	local byId: { [string]: Types.ClientCommand } = {}
	local byCode: { [number]: Types.ClientCommand } = {}
	local allowed: { [string]: boolean } = { id = true, code = true, target = true, request = true, result = true }

	for _, definition: any in raw do
		if type(definition) ~= "table" then
			return nil, nil, "MalformedBootstrap"
		end

		for field in next, definition do
			if type(field) ~= "string" or not allowed[field] then
				return nil, nil, "MalformedBootstrap"
			end
		end

		if
			type(definition.id) ~= "string"
			or definition.id == ""
			or type(definition.code) ~= "number"
			or not BufferUtils.IsOffset(definition.code, count - 1)
			or byId[definition.id] ~= nil
			or byCode[definition.code] ~= nil
			or (definition.target ~= "None" and definition.target ~= "Actor")
		then
			return nil, nil, "MalformedBootstrap"
		end

		local codecs: { [string]: Types.CompiledCodec } = {}

		for _, field: string in { "request", "result" } do
			if definition[field] ~= nil then
				local schema: Types.CompiledSchema?, schemaReason: string? = SchemaCompiler.Compile(definition[field])

				if schema == nil then
					return nil,
						nil,
						if schemaReason == "SchemaKindInvalid" then "UnsupportedSchema" else "MalformedBootstrap"
				end

				if schema.maxEncodedBytes > Constants.MAX_PAYLOAD_BYTES then
					return nil, nil, "CommandPayloadTooLarge"
				end

				local codec: Types.CompiledCodec?, codecReason: string? = CodecCompiler.Compile(schema)

				if codec == nil then
					return nil, nil, codecReason or "UnsupportedSchema"
				end

				codecs[field] = codec
			end
		end

		local installed: Types.ClientCommand = table.freeze({
			id = definition.id,
			code = definition.code,
			target = definition.target,
			requestCodec = codecs.request,
			resultCodec = codecs.result,
		})

		byId[installed.id] = installed
		byCode[installed.code] = installed
	end

	return table.freeze(byId), table.freeze(byCode), nil
end

return CommandManifest
