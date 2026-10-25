--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local Types = require(KRF.shared.Networking.types)
local Schema: Types.Schema = require(KRF.shared.Networking.Schema)
local Manifest = require(KRF.shared.Networking.ManifestCompiler)
local ProtocolConstants = require(KRF.shared.Networking.utils.ProtocolConstants)
local Constants = require(KRF.shared.Networking.utils.HintConstants)
local Module = require(KRF.shared.Networking.HintCodec)

local protocol = assert(Manifest.Reconstruct({
	version = ProtocolConstants.PROTOCOL_VERSION,
	domains = {},
	hints = {
		{
			id = "Game.Look",
			code = 0,
			direction = "ClientToServer",
			target = "Actor",
			mode = "Latest",
			payload = Schema.Struct({ value = Schema.U8 }),
		},
		{
			id = "Game.Pulse",
			code = 1,
			direction = "ClientToServer",
			target = "None",
			mode = "Pulse",
			payload = Schema.Optional(Schema.U8),
		},
		{
			id = "Game.Server",
			code = 2,
			direction = "ServerToClient",
			target = "None",
			mode = "Pulse",
			payload = Schema.U8,
		},
	},
}))

local codec = Module.Compile(protocol)

it("batches independently framed Latest and Pulse records and owns immutable decoded values", function()
	local first = assert(codec.EncodeRecord({ hintCode = 0, targetHandle = 7, sequence = 1, payload = { value = 9 } }))
	local second = assert(codec.EncodeRecord({ hintCode = 1 }))
	local packet = assert(codec.Pack({ first, second }))
	expect(buffer.len(packet) <= Constants.MAX_PACKET_BYTES).toBe(true)
	local cursor = assert(codec.Open(packet))
	local record, reason = codec.Read(cursor)
	expect(reason).toBeNil()
	expect(record).toEqual({ hintCode = 0, targetHandle = 7, sequence = 1, payload = { value = 9 } })
	assert(record ~= nil, "Expected decoded record")
	expect(table.isfrozen(record)).toBe(true)
	expect(table.isfrozen(record.payload)).toBe(true)
	record, reason = codec.Read(cursor)
	expect(reason).toBeNil()
	expect(record).toEqual({ hintCode = 1 })
	expect(cursor.remaining).toBe(0)
end)

it("rejects forged counts, missing optional header fields and truncated schema data", function()
	local record = assert(codec.EncodeRecord({ hintCode = 0, targetHandle = 7, sequence = 1, payload = { value = 9 } }))
	local packet = assert(codec.Pack({ record }))

	for _, count in { 0, Constants.MAX_RECORDS + 1, Constants.MAX_RECORDS } do
		local malformed = buffer.create(buffer.len(packet))
		buffer.copy(malformed, 0, packet)
		buffer.writeu32(malformed, 5, count)
		local cursor, reason = codec.Open(malformed)
		expect(cursor).toBeNil()
		expect(reason).toBe("MalformedHintPacket")
	end

	for _, length in { 11, 15, 19 } do
		local truncated = buffer.create(length)
		buffer.copy(truncated, 0, packet, 0, length)
		buffer.writeu32(truncated, 1, length)
		local cursor = assert(codec.Open(truncated))
		local decoded, reason = codec.Read(cursor)
		expect(decoded).toBeNil()
		expect(type(reason)).toBe("string")
	end

	local cursor = assert(codec.Open(packet))
	codec.Read(cursor)
	local decoded, reason = codec.Read(cursor)
	expect(decoded).toBeNil()
	expect(reason).toBe("MalformedHintPacket")
	local encoded, packReason = codec.Pack(table.create(Constants.MAX_RECORDS + 1, record))
	expect(encoded == nil).toBe(true)
	expect(packReason).toBe("HintPacketFull")
end)

it("defensively refuses oversized or failed codec output without producing a wire record", function()
	assert(protocol.hintsByCode ~= nil, "Expected Hint metadata")
	local hint: any = table.clone(protocol.hintsByCode[0])
	local payloadCodec: any = table.clone(hint.payloadCodec)

	hint.payloadCodec = payloadCodec

	local injected: Types.ClientProtocol = { domainsById = {}, domainsByCode = {}, hintsByCode = { [0] = hint } }
	local localCodec = Module.Compile(injected)
	local source = { hintCode = 0, targetHandle = 7, sequence = 1, payload = { value = 9 } }
	local originalMeasure = payloadCodec.Measure

	payloadCodec.Measure = function(): (number?, string?)
		return Constants.MAX_PACKET_BYTES, nil
	end

	local encoded, reason = localCodec.EncodeRecord(source)
	expect(encoded == nil).toBe(true)
	expect(reason).toBe("HintRecordTooLarge")
	payloadCodec.Measure = originalMeasure

	payloadCodec.Write = function(): (number?, string?)
		return nil, "InjectedWriteFailure"
	end

	encoded, reason = localCodec.EncodeRecord(source)
	expect(encoded == nil).toBe(true)
	expect(reason).toBe("InjectedWriteFailure")
end)

for _, invalid: any in
	{
		{ record = { hintCode = 255 }, reason = "UnknownHintCode" },
		{ record = { hintCode = 2, payload = 1 }, reason = "HintDirectionMismatch" },
		{ record = { hintCode = 0, sequence = 1, payload = { value = 9 } }, reason = "HintTargetMismatch" },
		{
			record = { hintCode = 0, targetHandle = 0, sequence = 1, payload = { value = 9 } },
			reason = "HintTargetMismatch",
		},
		{ record = { hintCode = 1, targetHandle = 7 }, reason = "HintTargetMismatch" },
		{
			record = { hintCode = 0, targetHandle = 7, sequence = 0, payload = { value = 9 } },
			reason = "InvalidHintSequence",
		},
		{ record = { hintCode = 1, sequence = 1 }, reason = "InvalidHintSequence" },
	}
do
	it("refuses invalid local record " .. invalid.reason, function()
		local record, reason = codec.EncodeRecord(invalid.record)
		expect(record == nil).toBe(true)
		expect(reason).toBe(invalid.reason)
	end)
end

it("rejects malformed payloads before returning a record", function()
	local record, reason =
		codec.EncodeRecord({ hintCode = 0, targetHandle = 7, sequence = 1, payload = { value = 256 } })

	expect(record == nil).toBe(true)
	expect(type(reason)).toBe("string")
end)

it("rejects malformed envelopes, extra bytes and truncation without throwing", function()
	local record = assert(codec.EncodeRecord({ hintCode = 0, targetHandle = 7, sequence = 1, payload = { value = 9 } }))
	local packet = assert(codec.Pack({ record }))

	for length = 0, buffer.len(packet) - 1 do
		local truncated = buffer.create(length)
		buffer.copy(truncated, 0, packet, 0, length)
		local cursor = codec.Open(truncated)
		expect(cursor).toBeNil()
	end

	for _, payload: any in { false, {}, "buffer", buffer.create(Constants.MAX_PACKET_BYTES + 1) } do
		local cursor, reason = codec.Open(payload)
		expect(cursor).toBeNil()
		expect(reason).toBe("MalformedHintPacket")
	end

	local trailing = buffer.create(buffer.len(packet) + 1)
	buffer.copy(trailing, 0, packet)
	buffer.writeu32(trailing, 1, buffer.len(trailing))
	local cursor = assert(codec.Open(trailing))
	local decoded, reason = codec.Read(cursor)
	expect(decoded).toBeNil()
	expect(reason).toBe("MalformedHintPacket")
end)

it("rejects zero and excessive batch counts and never fragments an oversized record", function()
	local packet, reason = codec.Pack({})
	expect(packet == nil).toBe(true)
	expect(reason).toBe("HintPacketFull")
	packet, reason = codec.Pack({ buffer.create(Constants.MAX_PACKET_BYTES) })
	expect(packet == nil).toBe(true)
	expect(reason).toBe("HintPacketFull")
end)

it("revalidates wire direction, targets, sequences and schema data", function()
	local record = assert(codec.EncodeRecord({ hintCode = 0, targetHandle = 7, sequence = 1, payload = { value = 9 } }))
	local packet = assert(codec.Pack({ record }))

	for _, mutation: any in
		{
			{ offset = 9, width = 2, value = 255, reason = "UnknownHintCode" },
			{ offset = 9, width = 2, value = 2, reason = "HintDirectionMismatch" },
			{ offset = 11, width = 4, value = 0, reason = "HintTargetMismatch" },
			{ offset = 15, width = 4, value = 0, reason = "InvalidHintSequence" },
		}
	do
		local malformed = buffer.create(buffer.len(packet))
		buffer.copy(malformed, 0, packet)

		if mutation.width == 2 then
			buffer.writeu16(malformed, mutation.offset, mutation.value)
		else
			buffer.writeu32(malformed, mutation.offset, mutation.value)
		end

		local cursor = assert(codec.Open(malformed))
		local decoded, reason = codec.Read(cursor)
		expect(decoded).toBeNil()
		expect(reason).toBe(mutation.reason)
	end
end)
