--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local SharedTypes = require(KRF.shared.Networking.types)
local Schema: SharedTypes.Schema = require(KRF.shared.Networking.Schema)
local Manifest = require(KRF.shared.Networking.ManifestCompiler)
local Constants = require(KRF.shared.Networking.utils.ProtocolConstants)
local CommandConstants = require(KRF.shared.Networking.utils.CommandConstants)
local Codec: SharedTypes.CommandCodecModule = require(KRF.shared.Networking.CommandCodec)

local function codec(): SharedTypes.CommandCodec
	local protocol: SharedTypes.ClientProtocol?, reason: string? = Manifest.Reconstruct({
		version = Constants.PROTOCOL_VERSION,
		domains = {},
		commands = {
			{
				id = "Game.Actor",
				code = 0,
				target = "Actor",
				request = Schema.Struct({ count = Schema.U8 }),
				result = Schema.U32,
			},
			{ id = "Game.Ping", code = 1, target = "None" },
			{
				id = "Game.Optional",
				code = 2,
				target = "None",
				request = Schema.Optional(Schema.U8),
				result = Schema.Optional(Schema.U8),
			},
		},
	})

	assert(protocol ~= nil, reason)

	return Codec.Compile(protocol)
end

it("round trips None and Actor requests with private handles and independently optional payloads", function()
	local compiled: SharedTypes.CommandCodec = codec()

	local requests: { SharedTypes.CommandRequest } = {
		{ commandCode = 0, requestId = 4294967295, targetHandle = 123, request = { count = 17 } },
		{ commandCode = 1, requestId = 1 },
		{ commandCode = 2, requestId = 2 },
		{ commandCode = 2, requestId = 3, request = 7 },
	}

	for _, request: SharedTypes.CommandRequest in requests do
		local encoded: buffer?, reason: string? = compiled.EncodeRequest(request)
		expect(reason).toBeNil()
		assert(encoded ~= nil, "Expected bounded request buffer")
		expect(buffer.readu8(encoded, 0)).toBe(CommandConstants.REQUEST_KIND)
		local decoded: SharedTypes.CommandRequest?, decodeReason: string? = compiled.DecodeRequest(encoded)
		expect(decodeReason).toBeNil()
		expect(decoded).toEqual(request)
	end
end)

it("round trips definitive results and separate Unknown notices without inventing Accepted payloads", function()
	local compiled: SharedTypes.CommandCodec = codec()

	local outcomes: { SharedTypes.CommandResult } = {
		{ commandCode = 0, requestId = 1, status = "Accepted", result = 4294967295 },
		{ commandCode = 1, requestId = 2, status = "Accepted" },
		{ commandCode = 0, requestId = 3, status = "Rejected", reason = "OutOfRange" },
		{ commandCode = 0, requestId = 4, status = "Unknown", reason = "CommandFault" },
		{ commandCode = 2, requestId = 5, status = "Accepted" },
	}

	for _, outcome: SharedTypes.CommandResult in outcomes do
		local encoded: buffer?, reason: string? = compiled.EncodeResult(outcome)
		expect(reason).toBeNil()
		assert(encoded ~= nil, "Expected bounded result buffer")
		expect(buffer.readu8(encoded, 0)).toBe(CommandConstants.RESULT_KIND)
		local decoded: SharedTypes.CommandResult?, decodeReason: string? = compiled.DecodeResult(encoded)
		expect(decodeReason).toBeNil()
		expect(decoded).toEqual(outcome)
	end
end)

for _, invalid: any in
	{
		{ commandCode = 9, requestId = 1 },
		{ commandCode = 1, requestId = 0 },
		{ commandCode = 1, requestId = 1.5 },
		{ commandCode = 1, requestId = 4294967296 },
		{ commandCode = 1, requestId = 1, targetHandle = 7 },
		{ commandCode = 0, requestId = 1, targetHandle = 0, request = { count = 1 } },
		{ commandCode = 0, requestId = 1, request = { count = 1 } },
		{ commandCode = 0, requestId = 1, targetHandle = 7, request = { count = 256 } },
		{ commandCode = 1, requestId = 1, request = false },
	}
do
	it(
		"rejects malformed request metadata/payload before encoding: "
			.. tostring(invalid.commandCode)
			.. "/"
			.. tostring(invalid.requestId),
		function()
			local encoded: buffer?, reason: string? = codec().EncodeRequest(invalid)
			expect(encoded == nil).toBe(true)
			expect(type(reason)).toBe("string")
		end
	)
end

it("rejects truncated, trailing, oversized and wrong-kind envelopes without throwing", function()
	local compiled: SharedTypes.CommandCodec = codec()

	local valid: buffer?, reason: string? =
		compiled.EncodeRequest({ commandCode = 0, requestId = 1, targetHandle = 7, request = { count = 1 } })

	assert(valid ~= nil, reason)

	for length: number = 0, buffer.len(valid) - 1 do
		local truncated: buffer = buffer.create(length)
		buffer.copy(truncated, 0, valid, 0, length)
		local decoded: SharedTypes.CommandRequest?, decodeReason: string? = compiled.DecodeRequest(truncated)
		expect(decoded).toBeNil()
		expect(type(decodeReason)).toBe("string")
	end

	local trailing: buffer = buffer.create(buffer.len(valid) + 1)
	buffer.copy(trailing, 0, valid)

	for _, invalid: any in
		{ trailing, buffer.create(CommandConstants.MAX_REQUEST_BYTES + 1), buffer.fromstring("unknown"), false, {} }
	do
		local decoded: SharedTypes.CommandRequest?, decodeReason: string? = compiled.DecodeRequest(invalid)
		expect(decoded).toBeNil()
		expect(type(decodeReason)).toBe("string")
	end
end)

it("rejects result contract faults and bounded rejection overflow", function()
	local compiled: SharedTypes.CommandCodec = codec()

	for _, outcome: any in
		{
			{ commandCode = 99, requestId = 1, status = "Accepted" },
			{ commandCode = 1, requestId = 0, status = "Accepted" },
			{ commandCode = 1, requestId = 1, status = "NotAStatus" },
			{ commandCode = 1, requestId = 1, status = "Accepted", reason = "Unexpected" },
			{ commandCode = 1, requestId = 1, status = "Rejected" },
			{ commandCode = 1, requestId = 1, status = "Rejected", reason = "" },
			{ commandCode = 0, requestId = 1, status = "Accepted", result = -1 },
			{ commandCode = 1, requestId = 1, status = "Accepted", result = {} },
			{
				commandCode = 1,
				requestId = 1,
				status = "Rejected",
				reason = string.rep("x", CommandConstants.MAX_REASON_BYTES + 1),
			},
			{ commandCode = 1, requestId = 1, status = "Rejected", reason = "NoEffect", result = 17 },
		}
	do
		local encoded: buffer?, reason: string? = compiled.EncodeResult(outcome)
		expect(encoded == nil).toBe(true)
		expect(type(reason)).toBe("string")
	end
end)

it("rejects tampered request codes, ids, target modes and optional payload discriminators", function()
	local compiled: SharedTypes.CommandCodec = codec()

	local requests: { { code: number, offset: number, value: number, width: number } } = {
		{ code = 1, offset = 1, value = 99, width = 2 },
		{ code = 1, offset = 3, value = 0, width = 4 },
		{ code = 0, offset = 7, value = 0, width = 4 },
		{ code = 1, offset = 7, value = 1, width = 4 },
		{ code = 2, offset = 11, value = 2, width = 1 },
	}

	for _, mutation in requests do
		local payload: buffer?, reason: string? = compiled.EncodeRequest({
			commandCode = mutation.code,
			requestId = 1,
			targetHandle = if mutation.code == 0 then 7 else nil,
			request = if mutation.code == 0 then { count = 1 } else nil,
		})

		assert(payload ~= nil, reason)

		if mutation.width == 1 then
			buffer.writeu8(payload, mutation.offset, mutation.value)
		elseif mutation.width == 2 then
			buffer.writeu16(payload, mutation.offset, mutation.value)
		else
			buffer.writeu32(payload, mutation.offset, mutation.value)
		end

		local result: SharedTypes.CommandRequest?, decodeReason: string? = compiled.DecodeRequest(payload)
		expect(result).toBeNil()
		expect(type(decodeReason)).toBe("string")
	end
end)

it("validates every result envelope before exposing a correlated outcome", function()
	local compiled: SharedTypes.CommandCodec = codec()

	local encoded: buffer?, reason: string? =
		compiled.EncodeResult({ commandCode = 0, requestId = 1, status = "Accepted", result = 17 })

	assert(encoded ~= nil, reason)

	for length: number = 0, buffer.len(encoded) - 1 do
		local truncated: buffer = buffer.create(length)
		buffer.copy(truncated, 0, encoded, 0, length)
		expect((compiled.DecodeResult(truncated))).toBeNil()
	end

	for _, mutation in
		{
			{ offset = 0, width = 1, value = 255 },
			{ offset = 1, width = 2, value = 99 },
			{ offset = 3, width = 4, value = 0 },
			{ offset = 7, width = 1, value = 9 },
		}
	do
		local invalid: buffer = buffer.fromstring(buffer.tostring(encoded))

		if mutation.width == 1 then
			buffer.writeu8(invalid, mutation.offset, mutation.value)
		elseif mutation.width == 2 then
			buffer.writeu16(invalid, mutation.offset, mutation.value)
		else
			buffer.writeu32(invalid, mutation.offset, mutation.value)
		end

		expect((compiled.DecodeResult(invalid))).toBeNil()
	end

	local rejection: buffer? =
		compiled.EncodeResult({ commandCode = 1, requestId = 1, status = "Rejected", reason = "Denied" })

	assert(rejection ~= nil, "Expected valid bounded rejection")

	for _, length: number in { 0, 65, 5, 7 } do
		buffer.writeu8(rejection, 8, length)
		expect((compiled.DecodeResult(rejection))).toBeNil()
	end

	local trailing: buffer = buffer.create(buffer.len(encoded) + 1)
	buffer.copy(trailing, 0, encoded)
	expect((compiled.DecodeResult(trailing))).toBeNil()
	expect((compiled.DecodeResult(buffer.create(CommandConstants.MAX_RESULT_BYTES + 1)))).toBeNil()
	local absent: buffer? = compiled.EncodeResult({ commandCode = 1, requestId = 1, status = "Accepted" })
	assert(absent ~= nil, "Expected no-schema result")
	buffer.writeu8(absent, 7, 1)
	expect((compiled.DecodeResult(absent))).toBeNil()
end)
