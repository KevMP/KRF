--!strict
local Types = require(script.Parent.Parent.types)

-- Private defaults, independent of package semver. Tests use these bounds rather
-- than promising their numeric values as consumer API.
-- Reject is one message-kind byte followed by one closed reason-code byte.
-- The symbolic reason remains available internally after decoding.
local rejectionCodes: { [Types.ProtocolRejectionReason]: number } = {
	ProtocolMismatch = 0,
	MalformedPacket = 1,
	UnsupportedSchema = 2,
	BootstrapTooLarge = 3,
	ReadyRejected = 4,
}
table.freeze(rejectionCodes)

return table.freeze({
	PROTOCOL_VERSION = 4,
	MAX_BOOTSTRAP_BYTES = 65536,
	INIT_TIMEOUT_SECONDS = 10,
	REJECT_PACKET_BYTES = 2,
	REJECTION_CODES = rejectionCodes,
})
