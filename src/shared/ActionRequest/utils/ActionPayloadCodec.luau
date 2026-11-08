--!strict
local Types = require(script.Parent.Parent.types)
local SchemaValidator = require(script.Parent.Parent.Parent.Networking.utils.SchemaValidator)
local Constants = require(script.Parent.ActionRequestConstants)

-- Inner payloads are written into an owned buffer and carried as a binary string, so
-- caller tables are never retained and the outer N9 String bound covers every byte.
local ActionPayloadCodec: Types.ActionPayloadCodecModule = table.freeze({
	Encode = function(payload: Types.CompiledActionPayload, value: any): (string?, string?)
		local schema = payload.schema
		local codec = payload.codec

		if schema == nil or codec == nil then
			return if value == nil then "" else nil, if value == nil then nil else "ActionPayloadUnexpected"
		end

		if not SchemaValidator.Validate(schema, value) then
			return nil, "ActionPayloadInvalid"
		end

		local size: number? = codec.Measure(value)

		if size == nil then
			return nil, "ActionPayloadInvalid"
		elseif size > Constants.MAX_PAYLOAD_BYTES then
			return nil, "ActionPayloadTooLarge"
		end

		local destination: buffer = buffer.create(size)
		local written: number? = codec.Write(value, destination, 0)

		if written ~= size then
			return nil, "ActionPayloadInvalid"
		end

		return buffer.tostring(destination), nil
	end,

	Decode = function(payload: Types.CompiledActionPayload, encoded: any): (boolean, any, string?)
		if type(encoded) ~= "string" then
			return false, nil, "ActionPayloadMalformed"
		elseif #encoded > Constants.MAX_PAYLOAD_BYTES then
			return false, nil, "ActionPayloadTooLarge"
		end

		local codec = payload.codec

		if codec == nil then
			if #encoded ~= 0 then
				return false, nil, "ActionPayloadTrailingBytes"
			end

			return true, nil, nil
		end

		local source: buffer = buffer.fromstring(encoded)
		local value: any, nextOffset: number? = codec.Read(source, 0, #encoded)

		if nextOffset == nil then
			return false, nil, "ActionPayloadMalformed"
		elseif nextOffset ~= #encoded then
			return false, nil, "ActionPayloadTrailingBytes"
		end

		return true, value, nil
	end,
})

return ActionPayloadCodec
