--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local Types = require(KRF.shared.Networking.types)
local Schema: Types.Schema = require(KRF.shared.Networking.Schema)
local Manifest = require(KRF.shared.Networking.ManifestCompiler)
local Constants = require(KRF.shared.Networking.utils.ProtocolConstants)
local Wire = require(KRF.shared.Networking.HintCodec)

local protocol = assert(Manifest.Reconstruct({
	version = Constants.PROTOCOL_VERSION,
	domains = {},
	hints = {
		{
			id = "Game.Input",
			code = 0,
			direction = "ClientToServer",
			target = "None",
			mode = "Pulse",
			payload = Schema.U8,
		},
		{
			id = "Game.Look",
			code = 1,
			direction = "ServerToClient",
			target = "Actor",
			mode = "Latest",
			payload = Schema.Struct({ value = Schema.U8 }),
		},
		{
			id = "Game.Pulse",
			code = 2,
			direction = "ServerToClient",
			target = "None",
			mode = "Pulse",
			payload = Schema.Optional(Schema.U8),
		},
	},
}))

local codec = Wire.Compile(protocol, "ServerToClient")

it("encodes recipient-local S2C Actor identity and batches immutable Latest and Pulse payloads", function()
	local first, reason = codec.EncodeRecord({ hintCode = 1, targetHandle = 7, sequence = 9, payload = { value = 4 } })
	expect(reason).toBeNil()
	assert(first ~= nil, "Expected S2C Latest record")
	local second = assert(codec.EncodeRecord({ hintCode = 2 }))
	local packet = assert(codec.Pack({ first, second }))
	expect(buffer.len(packet)).toBe(23)
	local cursor = assert(codec.Open(packet))
	local record = assert(codec.Read(cursor))
	expect(record).toEqual({ hintCode = 1, targetHandle = 7, sequence = 9, payload = { value = 4 } })
	expect(table.isfrozen(record.payload)).toBe(true)
	expect((codec.Read(cursor))).toEqual({ hintCode = 2 })
end)

it("rejects client-originated definitions at both S2C encoding and receipt", function()
	local encoded, reason = codec.EncodeRecord({ hintCode = 0, payload = 4 })
	expect(encoded).toBeNil()
	expect(reason).toBe("HintDirectionMismatch")
	local input = Wire.Compile(protocol)
	local record = assert(input.EncodeRecord({ hintCode = 0, payload = 4 }))
	local cursor = assert(codec.Open(assert(input.Pack({ record }))))
	local decoded, failure = codec.Read(cursor)
	expect(decoded).toBeNil()
	expect(failure).toBe("HintDirectionMismatch")
end)
