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
	-- S2C recipient admission counts encoded record bytes. Global bounds include
	-- staged send ownership. Pump bytes count complete physical packet payloads.
	SEND = table.freeze({
		windowSeconds = 1,
		maxAttempts = 256,
		maxBytes = 65536,
		maxGlobalAttempts = 2048,
		maxGlobalBytes = 524288,
		maxPending = 64,
		maxPendingBytes = 16384,
		maxGlobalPending = 512,
		maxGlobalPendingBytes = 131072,
		maxLatestKeys = 128,
		maxGlobalLatestKeys = 1024,
		maxSequence = 4294967295,
		maxRecords = 32,
		maxConnectionRecords = 8,
		maxSends = 4,
		maxStepBytes = 3600,
	}),
	-- Per-client S2C ingress: attempted packets/window, full packet bytes,
	-- retained complete packets/bytes, attempted dispatch records/pump and live keys.
	RECEIVE = table.freeze({
		windowSeconds = 1,
		maxPackets = 64,
		maxBytes = 57600,
		maxPendingPackets = 8,
		maxPendingBytes = 7200,
		maxRecords = 32,
		maxLatestKeys = 128,
	}),
}

function HintConstants.RecordBytes(payloadBytes: number, target: Types.HintTarget, mode: Types.HintMode): number
	return 2 + payloadBytes + (if target == "Actor" then 4 else 0) + (if mode == "Latest" then 4 else 0)
end

return table.freeze(HintConstants)
