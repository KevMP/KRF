--!strict
local Types = require(script.Parent.Parent.types)

-- Private startup admission bounds. Reserve the full packet envelope plus the
-- hint code, optional Actor handle and Latest sequence. Packetization fits this
-- allowance; definitions never rely on platform compression.
local HintConstants = {
	MAX_HINTS = 1024,
	MAX_PACKET_BYTES = 900,
	PACKET_HEADER_BYTES = 9,
	PACKET_KIND = 68,
	MAX_RECORDS = 32,
	MAX_COUNTER = 4294967295,
	WINDOW_SECONDS = 1,
	-- Per client: attempts/window, admitted record bytes/window, retained records/bytes.
	-- Latest replaces its pending sample; new work over a ceiling is refused.
	CLIENT_ATTEMPTS = 256,
	CLIENT_BYTES = 65536,
	PENDING_RECORDS = 64,
	PENDING_BYTES = 16384,
	LATEST_KEYS = 128,
	-- Attempted record visits/pump (each side); physical sends/client pump.
	STEP_RECORDS = 32,
	STEP_SENDS = 4,
	-- Server ingress: attempts and complete packet bytes/window, local then aggregate.
	SERVER_PACKETS = 64,
	SERVER_BYTES = 57600,
	GLOBAL_PACKETS = 512,
	GLOBAL_BYTES = 460800,
	-- Retained complete packets/bytes, including the staged dispatch packet.
	-- Overflow is dropped; dispatch releases capacity after callback unwind.
	PENDING_PACKETS = 8,
	PENDING_PACKET_BYTES = 7200,
	GLOBAL_PENDING_PACKETS = 128,
	GLOBAL_PENDING_BYTES = 115200,
	-- Retained receiver sequence keys across live connections; no historical eviction.
	GLOBAL_LATEST_KEYS = 1024,
}

function HintConstants.RecordBytes(payloadBytes: number, target: Types.HintTarget, mode: Types.HintMode): number
	return 2 + payloadBytes + (if target == "Actor" then 4 else 0) + (if mode == "Latest" then 4 else 0)
end

return table.freeze(HintConstants)
