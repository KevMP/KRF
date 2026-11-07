--!strict
local Types = require(script.Parent.Parent.types)

-- I5 TDD scaffold. Measure/copy into an owned buffer and binary-string conversion remain unimplemented.
local ActionPayloadCodec: Types.ActionPayloadCodecModule = table.freeze({
	Encode = function(_payload: Types.CompiledActionPayload, _value: any): (string?, string?)
		return nil, "ActionPayloadCodecUnavailable"
	end,
	Decode = function(_payload: Types.CompiledActionPayload, _encoded: any): (boolean, any, string?)
		return false, nil, "ActionPayloadCodecUnavailable"
	end,
})

return ActionPayloadCodec
