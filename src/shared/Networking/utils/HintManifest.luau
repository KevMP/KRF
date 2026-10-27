--!strict
local Types = require(script.Parent.Parent.types)
local Constants = require(script.Parent.HintConstants)
local Collections = require(script.Parent.SchemaCollectionUtils)
local BufferUtils = require(script.Parent.CodecBufferUtils)
local SchemaCompiler = require(script.Parent.SchemaCompiler)
local CodecCompiler = require(script.Parent.Parent.CodecCompiler)

local HintManifest = {}
local allowed = { id = true, code = true, direction = true, target = true, mode = true, payload = true }

function HintManifest.Compile(
	definitions: { Types.ManifestHint }?
): ({ [string]: Types.ClientHint }?, { [number]: Types.ClientHint }?, string?)
	local raw: any = if definitions ~= nil then definitions else {}
	local count = if type(raw) == "table" then Collections.GetArrayLength(raw) else nil

	if count == nil or count > Constants.MAX_HINTS then
		return nil, nil, "MalformedBootstrap"
	end

	local byId: { [string]: Types.ClientHint } = {}
	local byCode: { [number]: Types.ClientHint } = {}

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
			or (definition.direction ~= "ClientToServer" and definition.direction ~= "ServerToClient")
			or (definition.target ~= "None" and definition.target ~= "Actor")
			or (definition.mode ~= "Latest" and definition.mode ~= "Pulse")
		then
			return nil, nil, "MalformedBootstrap"
		end

		local payload, reason = SchemaCompiler.Compile(definition.payload)

		if payload == nil then
			return nil, nil, if reason == "SchemaKindInvalid" then "UnsupportedSchema" else "MalformedBootstrap"
		end

		if
			Constants.PACKET_HEADER_BYTES
				+ Constants.RecordBytes(payload.maxEncodedBytes, definition.target, definition.mode)
			> Constants.MAX_PACKET_BYTES
		then
			return nil, nil, "HintRecordTooLarge"
		end

		local codec, codecReason = CodecCompiler.Compile(payload)

		if codec == nil then
			return nil, nil, codecReason or "UnsupportedSchema"
		end

		local installed: Types.ClientHint = table.freeze({
			id = definition.id,
			code = definition.code,
			direction = definition.direction,
			target = definition.target,
			mode = definition.mode,
			payloadCodec = codec,
		})

		byId[installed.id], byCode[installed.code] = installed, installed
	end

	return table.freeze(byId), table.freeze(byCode), nil
end

return HintManifest
