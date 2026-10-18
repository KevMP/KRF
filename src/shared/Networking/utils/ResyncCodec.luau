--!strict
local Constants = require(script.Parent.ActorProtocolConstants)
local ResyncCodec = {}
export type Request = { read handle: number }

-- One private kind byte and one connection-local u32 handle.
function ResyncCodec.Encode(handle: number): (buffer?, string?)
	if
		type(handle) ~= "number"
		or handle ~= handle
		or handle < 1
		or handle > Constants.MAX_COUNTER
		or handle % 1 ~= 0
	then
		return nil, "InvalidActorHandle"
	end
	local payload: buffer = buffer.create(5)
	buffer.writeu8(payload, 0, Constants.RESYNC_PACKET_KIND)
	buffer.writeu32(payload, 1, handle)
	return payload, nil
end

function ResyncCodec.Decode(payload: any): (Request?, string?)
	if
		typeof(payload) ~= "buffer"
		or buffer.len(payload) ~= 5
		or buffer.readu8(payload, 0) ~= Constants.RESYNC_PACKET_KIND
	then
		return nil, "MalformedResyncRequest"
	end
	local handle: number = buffer.readu32(payload, 1)
	if handle == 0 then
		return nil, "MalformedResyncRequest"
	end
	return table.freeze({ handle = handle }), nil
end

return ResyncCodec
