--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF

local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local ProtocolTypes = require(KRF.shared.Networking.ProtocolTypes)
local Constants = require(KRF.shared.Networking.ProtocolConstants)
local Codec: ProtocolTypes.ProtocolCodec = require(KRF.shared.Networking.ProtocolCodec)
local TestUtils = require(script.Parent.Parent.Utils.Networking.ProtocolTestUtils)

local messages: { ProtocolTypes.Message } = {
	{ kind = "Hello", version = Constants.PROTOCOL_VERSION },
	{ kind = "Ready" },
	{ kind = "ReadyAck" },
	{ kind = "Reject", reason = "ProtocolMismatch" },
	{ kind = "Bootstrap", manifest = TestUtils.manifest() },
}
for _, message: ProtocolTypes.Message in messages do
	it("multiplexes " .. message.kind .. " through a single buffer payload", function()
		local encoded: buffer = TestUtils.encode(message)
		expect(typeof(encoded)).toBe("buffer")
		expect(TestUtils.decode(encoded)).toEqual(message)
	end)
end

it("keeps client handshake packets tiny and rejects trailing arbitrary payloads", function()
	for _, message: ProtocolTypes.Message in { messages[1], messages[2] } do
		local encoded: buffer = TestUtils.encode(message)
		expect(buffer.len(encoded) <= 16).toBe(true)
		local padded: buffer = buffer.create(buffer.len(encoded) + 1)
		buffer.copy(padded, 0, encoded)
		local decoded: ProtocolTypes.Message?, reason: string? = Codec.Decode(padded)
		expect(decoded).toBeNil()
		expect(reason).toBe("MalformedPacket")
	end
end)

it("rejects truncated framing at every byte boundary without throwing", function()
	for _, message: ProtocolTypes.Message in messages do
		local encoded: buffer = TestUtils.encode(message)
		for length: number = 0, buffer.len(encoded) - 1 do
			local source: buffer = buffer.create(length)
			buffer.copy(source, 0, encoded, 0, length)
			local decoded: ProtocolTypes.Message? = nil
			local reason: string? = nil
			local completed: boolean = pcall(function()
				decoded, reason = Codec.Decode(source)
			end)
			expect(completed).toBe(true)
			expect(decoded).toBeNil()
			expect(reason).toBe("MalformedPacket")
		end
	end
end)

it("rejects tables, strings, numbers and Instances at the protocol boundary", function()
	local instance: Folder = Instance.new("Folder")
	for _, payload: any in { {}, "hello", 1, false, instance } do
		local decoded: ProtocolTypes.Message?, reason: string? = Codec.Decode(payload)
		expect(decoded).toBeNil()
		expect(reason).toBe("ProtocolPayloadMustBeBuffer")
	end
	instance:Destroy()
	local decoded: ProtocolTypes.Message?, reason: string? = Codec.Decode(nil)
	expect(decoded).toBeNil()
	expect(reason).toBe("ProtocolPayloadMustBeBuffer")
end)

it("rejects unknown opcodes rather than dispatching them as recognized work", function()
	local source: buffer = buffer.create(1)
	buffer.writeu8(source, 0, 255)
	local decoded: ProtocolTypes.Message?, reason: string? = Codec.Decode(source)
	expect(decoded).toBeNil()
	expect(reason).toBe("UnknownMessageKind")
end)

it("rejects oversized bootstrap buffers before interpreting their contents", function()
	local encoded: buffer = TestUtils.encode({ kind = "Bootstrap", manifest = TestUtils.manifest() })
	local source: buffer = buffer.create(Constants.MAX_BOOTSTRAP_BYTES + 1)
	buffer.copy(source, 0, encoded)
	local decoded: ProtocolTypes.Message?, reason: string? = Codec.Decode(source)
	expect(decoded).toBeNil()
	expect(reason).toBe("BootstrapTooLarge")
end)
