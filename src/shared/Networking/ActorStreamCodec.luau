--!strict
local Types = require(script.Parent.ActorStreamTypes)
local ProtocolTypes = require(script.Parent.ProtocolTypes)

local ActorStreamCodec = {} :: Types.CodecModule

function ActorStreamCodec.Compile(_protocol: ProtocolTypes.ClientProtocol, _schemas: Types.SchemaCatalog): Types.Codec
	return {
		Encode = function(_records: { Types.Record }): (buffer?, string?)
			error("N4NotImplemented:ActorStreamCodec.Encode")
		end,
		Decode = function(_payload: any): ({ Types.Record }?, string?)
			error("N4NotImplemented:ActorStreamCodec.Decode")
		end,
		EncodeBaseline = function(_domains: { [string]: Types.DomainTruth }): (buffer?, string?)
			error("N4NotImplemented:ActorStreamCodec.EncodeBaseline")
		end,
		DecodeBaseline = function(_payload: buffer): ({ [string]: Types.DomainTruth }?, string?)
			error("N4NotImplemented:ActorStreamCodec.DecodeBaseline")
		end,
	}
end

return ActorStreamCodec
