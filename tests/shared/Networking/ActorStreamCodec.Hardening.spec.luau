--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF

local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local SharedNetworkingTypes = require(KRF.shared.Networking.types)
local Schema: SharedNetworkingTypes.Schema = require(KRF.shared.Networking.Schema)
local Codec: SharedNetworkingTypes.ActorStreamCodecModule = require(KRF.shared.Networking.ActorStreamCodec)
local TestUtils = require(script.Parent.Parent.Utils.Networking.ActorStreamCodecTestUtils)

local codec: SharedNetworkingTypes.ActorStreamCodec

beforeEach(function()
	codec = TestUtils.codec()
end)

for _, input: any in { false, 123, "packet", {} } do
	it("rejects non-buffer protocol input of type " .. typeof(input), function()
		local records: { SharedNetworkingTypes.ActorStreamRecord }?, reason: string? = codec.Decode(input)
		expect(records).toBeNil()
		expect(reason).toBe("MalformedActorPacket")
	end)
end

it("rejects nil and all single-byte packets without throwing or exposing partial records", function()
	local records: { SharedNetworkingTypes.ActorStreamRecord }?, reason: string? = codec.Decode(nil)
	expect(records).toBeNil()
	expect(reason).toBe("MalformedActorPacket")

	for byte: number = 0, 255 do
		local payload: buffer = buffer.create(1)
		buffer.writeu8(payload, 0, byte)
		records, reason = codec.Decode(payload)
		expect(records).toBeNil()
		expect(reason).toBe("MalformedActorPacket")
	end
end)

it("rejects every truncated prefix of a mixed Actor packet without returning a valid prefix", function()
	local payload: buffer = TestUtils.encode(codec, {
		{ kind = "BaselineBegin", handle = 1, actorId = "ActorA", generation = 1, totalBytes = 3 },
		{ kind = "BaselineChunk", handle = 1, generation = 1, offset = 0, bytes = buffer.fromstring("abc") },
		{ kind = "BaselineEnd", handle = 1, generation = 1, revision = 1 },
		{
			kind = "Commit",
			handle = 1,
			revision = 2,
			patches = {},
			events = { { domainId = "Game.State", eventId = "Changed", payload = { count = 1 } } },
		},
	})

	for length: number = 0, buffer.len(payload) - 1 do
		local prefix: buffer = buffer.create(length)
		buffer.copy(prefix, 0, payload, 0, length)
		local records: { SharedNetworkingTypes.ActorStreamRecord }?, reason: string? = codec.Decode(prefix)
		expect(records).toBeNil()
		expect(reason).toBe("MalformedActorPacket")
	end
end)

it("rejects unexplained trailing bytes after a complete physical packet", function()
	local payload: buffer = TestUtils.encode(codec, { { kind = "ActorRemove", handle = 1 } })
	local padded: buffer = buffer.create(buffer.len(payload) + 1)
	buffer.copy(padded, 0, payload)
	buffer.writeu8(padded, buffer.len(payload), 255)
	local records: { SharedNetworkingTypes.ActorStreamRecord }?, reason: string? = codec.Decode(padded)
	expect(records).toBeNil()
	expect(reason).toBe("MalformedActorPacket")
end)

it("rejects a domain code absent from the receiving compiled catalog", function()
	local foreign: SharedNetworkingTypes.ActorStreamCodec = Codec.Compile(TestUtils.protocol(7, nil))

	local payload: buffer = TestUtils.encode(foreign, {
		{
			kind = "Commit",
			handle = 1,
			revision = 2,
			patches = {
				{
					domainId = "Game.State",
					patch = { kind = "Struct", fields = { current = { kind = "Replace", value = 80 } } },
				},
			},
			events = {},
		},
	})

	local records: { SharedNetworkingTypes.ActorStreamRecord }?, reason: string? = codec.Decode(payload)
	expect(records).toBeNil()
	expect(reason).toBe("UnknownDomainCode")
end)

it("rejects an event code absent from the receiving domain without dispatching game code", function()
	local foreign: SharedNetworkingTypes.ActorStreamCodec = Codec.Compile(TestUtils.protocol(nil, 7))

	local payload: buffer = TestUtils.encode(foreign, {
		{
			kind = "Commit",
			handle = 1,
			revision = 2,
			patches = {},
			events = { { domainId = "Game.State", eventId = "Changed", payload = { count = 1 } } },
		},
	})

	local records: { SharedNetworkingTypes.ActorStreamRecord }?, reason: string? = codec.Decode(payload)
	expect(records).toBeNil()
	expect(reason).toBe("UnknownEventCode")
end)

local invalidPatches: { { name: string, patch: SharedNetworkingTypes.ActorPatch } } = {
	{
		name = "a numeric overflow",
		patch = { kind = "Struct", fields = { current = { kind = "Replace", value = 256 } } },
	},
	{
		name = "an unknown field",
		patch = { kind = "Struct", fields = { unexpected = { kind = "Replace", value = 1 } } },
	},
	{
		name = "an oversized Array",
		patch = { kind = "Struct", fields = { order = { kind = "Replace", value = { 1, 2, 3, 4 } } } },
	},
	{
		name = "an oversized Map",
		patch = {
			kind = "Struct",
			fields = { items = { kind = "Map", entries = { A = 1, B = 2, C = 3 }, removed = {} } },
		},
	},
	{
		name = "an oversized Optional String",
		patch = { kind = "Struct", fields = { target = { kind = "Replace", value = "TooLongTarget" } } },
	},
}

for _, case: { name: string, patch: SharedNetworkingTypes.ActorPatch } in invalidPatches do
	it("rejects " .. case.name .. " before returning packet bytes", function()
		local payload: buffer?, reason: string? = codec.Encode({
			{
				kind = "Commit",
				handle = 1,
				revision = 2,
				patches = { { domainId = "Game.State", patch = case.patch } },
				events = {},
			},
		})

		expect(payload).toBeNil()
		expect(reason).toBe("InvalidActorPatch")
	end)
end

it("enforces receiving Array bounds during patch decode even when a foreign sender permits more entries", function()
	local foreign: SharedNetworkingTypes.ActorStreamCodec = Codec.Compile(TestUtils.protocol(
		nil,
		nil,
		Schema.Struct({
			current = Schema.U8,
			target = Schema.Optional(Schema.String(8)),
			items = Schema.Map(Schema.String(8), Schema.U8, 2),
			order = Schema.Array(Schema.U8, 4),
		})
	))

	local payload: buffer = TestUtils.encode(foreign, {
		{
			kind = "Commit",
			handle = 1,
			revision = 2,
			patches = {
				{
					domainId = "Game.State",
					patch = {
						kind = "Struct",
						fields = {
							order = { kind = "Replace", value = { 1, 2, 3, 4 } },
						},
					},
				},
			},
			events = {},
		},
	})

	local records: { SharedNetworkingTypes.ActorStreamRecord }?, reason: string? = codec.Decode(payload)
	expect(records).toBeNil()
	expect(reason).toBe("InvalidActorPatch")
end)

it("enforces receiving baseline bounds before handing current truth to the client", function()
	local foreign: SharedNetworkingTypes.ActorStreamCodec = Codec.Compile(TestUtils.protocol(
		nil,
		nil,
		Schema.Struct({
			current = Schema.U8,
			target = Schema.Optional(Schema.String(16)),
			items = Schema.Map(Schema.String(8), Schema.U8, 2),
			order = Schema.Array(Schema.U8, 3),
		})
	))

	local payload: buffer?, reason: string? = foreign.EncodeBaseline({
		["Game.State"] = { value = {
			current = 100,
			target = "123456789",
			items = {},
			order = {},
		} },
	})

	expect(reason).toBeNil()
	assert(payload ~= nil, "Expected foreign baseline bytes")

	local domains: { [string]: SharedNetworkingTypes.ActorDomainTruth }?, decodeReason: string? =
		codec.DecodeBaseline(payload)

	expect(domains).toBeNil()
	expect(decodeReason).toBe("InvalidActorBaseline")
end)

it("rejects event payloads outside their compiled schema bounds", function()
	local payload: buffer?, reason: string? = codec.Encode({
		{
			kind = "Commit",
			handle = 1,
			revision = 2,
			patches = {},
			events = { { domainId = "Game.State", eventId = "Changed", payload = { count = 256 } } },
		},
	})

	expect(payload).toBeNil()
	expect(reason).toBe("InvalidActorEvent")
end)

it("never serializes a Model Instance as Actor state or identity", function()
	local model: Model = Instance.new("Model")

	local success: boolean, payload: buffer?, reason: string? =
		pcall(codec.EncodeBaseline, { ["Game.Optional"] = { value = model } })

	model:Destroy()
	expect(success).toBe(true)
	expect(payload).toBeNil()
	expect(reason).toBe("InvalidActorBaseline")
end)
