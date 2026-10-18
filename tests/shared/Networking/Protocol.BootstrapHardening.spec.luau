--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF

local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local SharedNetworkingTypes = require(KRF.shared.Networking.types)
local Schema: SharedNetworkingTypes.Schema = require(KRF.shared.Networking.Schema)
local Constants = require(KRF.shared.Networking.utils.ProtocolConstants)
local Codec: SharedNetworkingTypes.ProtocolCodec = require(KRF.shared.Networking.ProtocolCodec)
local TestUtils = require(script.Parent.Parent.Utils.Networking.ProtocolTestUtils)

local DOMAIN_ID: string = "Game.Hostile"
-- Private bootstrap layout: opcode, version, count, id length/id, domain code.
local SCHEMA_OFFSET: number = 1 + 2 + 4 + 4 + #DOMAIN_ID + 2

local function message(definition: SharedNetworkingTypes.SchemaDefinition): SharedNetworkingTypes.ProtocolMessage
	return {
		kind = "Bootstrap",
		manifest = {
			version = Constants.PROTOCOL_VERSION,
			domains = { { id = DOMAIN_ID, code = 0, state = definition, events = {} } },
		},
	}
end

local function expectDecodeFailure(payload: buffer, expectedReason: string): ()
	local decoded: SharedNetworkingTypes.ProtocolMessage? = nil
	local reason: string? = nil

	local completed: boolean = pcall(function()
		decoded, reason = Codec.Decode(payload)
	end)

	expect(completed).toBe(true)
	expect(decoded).toBeNil()
	expect(reason).toBe(expectedReason)
end

it("rejects unsupported schema tags on encode and decode without guessing at a codec", function()
	local encoded: buffer?, reason: string? = Codec.Encode(message({ kind = "FutureSchema" } :: any))
	expect(encoded).toBeNil()
	expect(reason).toBe("UnsupportedSchema")
	local payload: buffer = TestUtils.encode(message(Schema.U8))
	buffer.writeu8(payload, SCHEMA_OFFSET, 255)
	expectDecodeFailure(payload, "UnsupportedSchema")
end)

it("rejects unsafe-integer schema bounds on encode and decode instead of rounding or truncating them", function()
	local encoded: buffer?, reason: string? = Codec.Encode(message({ kind = "String", maxBytes = 2 ^ 53 }))
	expect(encoded).toBeNil()
	expect(reason).toBe("InvalidProtocolManifest")
	local payload: buffer = TestUtils.encode(message(Schema.String(8)))
	buffer.writeu32(payload, SCHEMA_OFFSET + 1, 0)
	buffer.writeu32(payload, SCHEMA_OFFSET + 5, 2 ^ 21)
	expectDecodeFailure(payload, "MalformedPacket")
end)

it("rejects oversized domain codes rather than narrowing them into valid identities", function()
	local packet: SharedNetworkingTypes.ProtocolMessage = message(Schema.U8)
	assert(packet.kind == "Bootstrap", "Expected Bootstrap")

	local source: any = packet.manifest.domains[1]
	source.code = 65536
	local encoded: buffer?, reason: string? = Codec.Encode(packet)
	expect(encoded).toBeNil()
	expect(reason).toBe("InvalidProtocolManifest")
end)

it("rejects excessive schema depth before encode or decode can exhaust the call stack", function()
	local definition: SharedNetworkingTypes.SchemaDefinition = Schema.U8

	for _ = 1, 129 do
		definition = { kind = "Optional", inner = definition }
	end

	local encoded: buffer?, reason: string? = Codec.Encode(message(definition))
	expect(encoded).toBeNil()
	expect(reason).toBe("InvalidProtocolManifest")
	local valid: buffer = TestUtils.encode(message(Schema.Optional(Schema.U8)))
	local payload: buffer = buffer.create(SCHEMA_OFFSET + 129 + 1 + 4)
	buffer.copy(payload, 0, valid, 0, SCHEMA_OFFSET)
	buffer.fill(payload, SCHEMA_OFFSET, buffer.readu8(valid, SCHEMA_OFFSET), 129)
	buffer.writeu8(payload, SCHEMA_OFFSET + 129, buffer.readu8(valid, SCHEMA_OFFSET + 1))
	expectDecodeFailure(payload, "MalformedPacket")
end)

it("rejects duplicate encoded Struct field names instead of overwriting their schema", function()
	local payload: buffer = TestUtils.encode(message(Schema.Struct({ aa = Schema.U8, bb = Schema.Boolean })))
	buffer.writestring(payload, SCHEMA_OFFSET + 16, "aa")
	expectDecodeFailure(payload, "MalformedPacket")
end)

it("rejects claimed manifest cardinality beyond the remaining bytes before allocating entries", function()
	local payload: buffer = TestUtils.encode(message(Schema.U8))
	buffer.writeu32(payload, 3, 4294967295)
	expectDecodeFailure(payload, "MalformedPacket")
end)

it("rejects extra bytes after the complete bootstrap manifest", function()
	local valid: buffer = TestUtils.encode(message(Schema.U8))
	local payload: buffer = buffer.create(buffer.len(valid) + 1)
	buffer.copy(payload, 0, valid)
	expectDecodeFailure(payload, "MalformedPacket")
end)
