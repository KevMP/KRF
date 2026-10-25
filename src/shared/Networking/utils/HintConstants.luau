--!strict
local Types = require(script.Parent.Parent.types)

-- Private startup admission bounds. Reserve the full packet envelope plus the
-- hint code, optional Actor handle and Latest sequence. The later packet codec
-- must fit this allowance; definitions never rely on platform compression.
local HintConstants = {
	MAX_HINTS = 1024,
	MAX_PACKET_BYTES = 900,
	PACKET_HEADER_BYTES = 9,
}

function HintConstants.RecordBytes(payloadBytes: number, target: Types.HintTarget, mode: Types.HintMode): number
	return 2 + payloadBytes + (if target == "Actor" then 4 else 0) + (if mode == "Latest" then 4 else 0)
end

return table.freeze(HintConstants)
