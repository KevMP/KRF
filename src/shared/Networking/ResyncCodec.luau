--!strict
local ResyncCodec = {}
export type Request = { read handle: number }

-- Private Reliable control codec. N5 implementation will choose the wire layout.
function ResyncCodec.Encode(_handle: number): (buffer?, string?)
	return nil, "N5NotImplemented"
end

function ResyncCodec.Decode(_payload: any): (Request?, string?)
	return nil, "N5NotImplemented"
end

return ResyncCodec
