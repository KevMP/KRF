--!strict
local ProtocolTypes = require(script.Parent.ProtocolTypes)

local ProtocolCodec = {} :: ProtocolTypes.ProtocolCodec

function ProtocolCodec.Encode(_message: ProtocolTypes.Message): (buffer?, string?)
	return nil, "N2NotImplemented"
end

function ProtocolCodec.Decode(_payload: any): (ProtocolTypes.Message?, string?)
	return nil, "N2NotImplemented"
end

return ProtocolCodec
