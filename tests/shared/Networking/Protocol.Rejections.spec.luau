--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF

local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local SharedNetworkingTypes = require(KRF.shared.Networking.types)
local Constants = require(KRF.shared.Networking.utils.ProtocolConstants)
local Codec: SharedNetworkingTypes.ProtocolCodec = require(KRF.shared.Networking.ProtocolCodec)
local TestUtils = require(script.Parent.Parent.Utils.Networking.ProtocolTestUtils)

local rejectionReasons: { SharedNetworkingTypes.ProtocolRejectionReason } = {
	"ProtocolMismatch",
	"MalformedPacket",
	"UnsupportedSchema",
	"BootstrapTooLarge",
	"ReadyRejected",
}

it("owns a frozen closed rejection codebook with unique one-byte codes", function()
	local codes: { [number]: boolean } = {}
	local count: number = 0

	for reason: SharedNetworkingTypes.ProtocolRejectionReason, code: number in Constants.REJECTION_CODES do
		expect(table.find(rejectionReasons, reason)).never.toBeNil()
		expect(code >= 0 and code <= 255 and code % 1 == 0).toBe(true)
		expect(codes[code]).toBeNil()
		codes[code] = true
		count += 1
	end

	expect(count).toBe(#rejectionReasons)
	expect(table.isfrozen(Constants.REJECTION_CODES)).toBe(true)
	expect(Constants.REJECT_PACKET_BYTES).toBe(2)
end)

for _, rejectionReason: SharedNetworkingTypes.ProtocolRejectionReason in rejectionReasons do
	it("encodes " .. rejectionReason .. " as a fixed-size reason code rather than a diagnostic string", function()
		local payload: buffer = TestUtils.encode({ kind = "Reject", reason = rejectionReason })
		expect(buffer.len(payload)).toBe(Constants.REJECT_PACKET_BYTES)
		expect(buffer.readu8(payload, 1)).toBe(Constants.REJECTION_CODES[rejectionReason])
		expect(TestUtils.decode(payload)).toEqual({ kind = "Reject", reason = rejectionReason })
	end)
end

type InvalidReasonCase = { name: string, value: any }

local invalidReasons: { InvalidReasonCase } = {
	{ name = "missing reason" },
	{ name = "empty reason", value = "" },
	{ name = "unknown reason", value = "ConsumerDiagnostic" },
	{ name = "oversized diagnostic", value = string.rep("x", Constants.MAX_BOOTSTRAP_BYTES + 1) },
	{ name = "numeric reason", value = 0 },
	{ name = "Boolean reason", value = false },
	{ name = "table reason", value = { reason = "ProtocolMismatch" } },
}

for _, testCase: InvalidReasonCase in invalidReasons do
	it("rejects " .. testCase.name .. " without producing any handshake buffer", function()
		local payload: buffer? = nil
		local reason: string? = nil

		local completed: boolean = pcall(function()
			-- Exercise the runtime boundary even when a caller bypasses static types.
			local message: any = { kind = "Reject", reason = testCase.value }
			payload, reason = Codec.Encode(message)
		end)

		expect(completed).toBe(true)
		expect(payload).toBeNil()
		expect(reason).toBe("ProtocolRejectionReasonInvalid")
	end)
end

it("rejects an unknown wire reason code instead of decoding it as arbitrary text", function()
	local payload: buffer = TestUtils.encode({ kind = "Reject", reason = "ProtocolMismatch" })
	buffer.writeu8(payload, 1, 255)
	local message: SharedNetworkingTypes.ProtocolMessage?, reason: string? = Codec.Decode(payload)
	expect(message).toBeNil()
	expect(reason).toBe("ProtocolRejectionReasonInvalid")
end)

it("rejects every truncation of the fixed rejection packet without throwing", function()
	local valid: buffer = TestUtils.encode({ kind = "Reject", reason = "ReadyRejected" })

	for length: number = 0, Constants.REJECT_PACKET_BYTES - 1 do
		local payload: buffer = buffer.create(length)
		buffer.copy(payload, 0, valid, 0, length)
		local message: SharedNetworkingTypes.ProtocolMessage? = nil
		local reason: string? = nil

		local completed: boolean = pcall(function()
			message, reason = Codec.Decode(payload)
		end)

		expect(completed).toBe(true)
		expect(message).toBeNil()
		expect(reason).toBe("MalformedPacket")
	end
end)

for _, length: number in { 3, Constants.MAX_BOOTSTRAP_BYTES + 1 } do
	it(
		"rejects a Reject opcode with "
			.. tostring(length)
			.. " bytes rather than interpreting an appended reason string",
		function()
			local valid: buffer = TestUtils.encode({ kind = "Reject", reason = "ReadyRejected" })
			local payload: buffer = buffer.create(length)
			buffer.copy(payload, 0, valid)
			buffer.fill(payload, Constants.REJECT_PACKET_BYTES, (string.byte("x")))
			local message: SharedNetworkingTypes.ProtocolMessage? = nil
			local reason: string? = nil

			local completed: boolean = pcall(function()
				message, reason = Codec.Decode(payload)
			end)

			expect(completed).toBe(true)
			expect(message).toBeNil()
			expect(reason).toBe("MalformedPacket")
		end
	)
end
