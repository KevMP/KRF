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
local Compiler: SharedNetworkingTypes.ManifestCompiler = require(KRF.shared.Networking.ManifestCompiler)
local TestUtils = require(script.Parent.Parent.Utils.Networking.ProtocolTestUtils)

-- Private wire layout: a reference is one kind byte then a U32 index, and every
-- bootstrap ends with empty command and hint counts.
local REFERENCE_KIND: number = 15
local TRAILER_BYTES: number = 8

local function ids(count: number, format: string?): { string }
	local values: { string } = {}

	for index: number = 1, count do
		table.insert(values, string.format(format or "Combat.Action%06d", index))
	end

	return values
end

-- Mirrors the visible Actions domain: one id Enum in state and in every lifecycle event.
local function message(values: { string }, eventCount: number): SharedNetworkingTypes.ProtocolMessage
	local events: { SharedNetworkingTypes.ManifestEvent } = {}

	for index: number = 1, eventCount do
		table.insert(events, {
			id = "Event" .. index,
			code = index - 1,
			payload = Schema.Struct({ actionId = Schema.Enum(values), sequenceId = Schema.U32 }),
		})
	end

	return {
		kind = "Bootstrap",
		manifest = {
			version = Constants.PROTOCOL_VERSION,
			domains = {
				{
					id = "KRF.Actions",
					code = 0,
					state = Schema.Array(Schema.Struct({ actionId = Schema.Enum(values) }), 8),
					events = events,
				},
			},
		},
	}
end

local function decodeFailure(payload: buffer): string?
	local decoded: SharedNetworkingTypes.ProtocolMessage?, reason: string? = Codec.Decode(payload)
	expect(decoded).toBeNil()

	return reason
end

it("encodes repeated identical Enums once and references the first copy", function()
	local interned: buffer = TestUtils.encode(message(ids(800), 3))
	local single: buffer = TestUtils.encode(message(ids(800), 0))
	local inlineEnumBytes: number = 4 + 800 * (4 + #"Combat.Action000001")

	expect(buffer.len(interned) < buffer.len(single) + inlineEnumBytes).toBe(true)
	expect(buffer.len(interned) <= Constants.MAX_BOOTSTRAP_BYTES).toBe(true)
end)

it("round-trips interned Enums to equal values and reconstructs a usable protocol", function()
	local source: SharedNetworkingTypes.ProtocolMessage = message(ids(200), 3)
	local decoded: SharedNetworkingTypes.ProtocolMessage = TestUtils.decode(TestUtils.encode(source))
	assert(decoded.kind == "Bootstrap" and source.kind == "Bootstrap", "Expected bootstrap messages")

	expect(decoded.manifest).toEqual(source.manifest)

	local events: { SharedNetworkingTypes.ManifestEvent } = decoded.manifest.domains[1].events
	local first: any = events[1].payload
	local second: any = events[2].payload
	expect(second.fields.actionId.values).toBe(first.fields.actionId.values)
	expect(table.isfrozen(first.fields.actionId.values)).toBe(true)

	local protocol: SharedNetworkingTypes.ClientProtocol?, reason: string? = Compiler.Reconstruct(decoded.manifest)
	expect(reason).toBeNil()
	expect(protocol).never.toBeNil()
end)

it("re-encodes a decoded interned bootstrap to identical bytes", function()
	local payload: buffer = TestUtils.encode(message(ids(50), 3))
	local decoded: SharedNetworkingTypes.ProtocolMessage = TestUtils.decode(payload)
	expect(buffer.tostring(TestUtils.encode(decoded))).toBe(buffer.tostring(payload))
end)

it("keeps distinct Enums inline even when their values overlap", function()
	local decoded: SharedNetworkingTypes.ProtocolMessage = TestUtils.decode(TestUtils.encode({
		kind = "Bootstrap",
		manifest = {
			version = Constants.PROTOCOL_VERSION,
			domains = {
				{
					id = "Game.Modes",
					code = 0,
					state = Schema.Struct({
						first = Schema.Enum({ "A", "B" }),
						second = Schema.Enum({ "A", "B", "C" }),
					}),
					events = {},
				},
			},
		},
	}))

	assert(decoded.kind == "Bootstrap", "Expected a bootstrap message")
	local state: any = decoded.manifest.domains[1].state
	expect(state.fields.first.values).toEqual({ "A", "B" })
	expect(state.fields.second.values).toEqual({ "A", "B", "C" })
end)

it("rejects a reference to an Enum that has not been decoded yet", function()
	local payload: buffer = TestUtils.encode(message(ids(4), 1))
	-- The event payload's reference precedes its final sequenceId field (name and U32 kind).
	local reference: number = buffer.len(payload) - TRAILER_BYTES - (4 + #"sequenceId" + 1) - 5
	expect(buffer.readu8(payload, reference)).toBe(REFERENCE_KIND)
	buffer.writeu32(payload, reference + 1, 1)
	expect(decodeFailure(payload)).toBe("MalformedPacket")
end)

it("rejects a reference that appears before any Enum", function()
	local payload: buffer = TestUtils.encode({
		kind = "Bootstrap",
		manifest = {
			version = Constants.PROTOCOL_VERSION,
			domains = { { id = "Game.Plain", code = 0, state = Schema.U32, events = {} } },
		},
	})

	-- Replace the U32 kind byte with a reference whose index runs into the trailer.
	buffer.writeu8(payload, 1 + 2 + 4 + 4 + #"Game.Plain" + 2, REFERENCE_KIND)
	expect(decodeFailure(payload)).toBe("MalformedPacket")
end)

it("refuses to encode references that would exceed the decoded Enum work budget", function()
	-- The interned bytes fit the bound, but five copies describe too many decoded values.
	local encoded: buffer?, reason: string? = Codec.Encode(message(ids(4000, "%d"), 4))
	expect(encoded).toBeNil()
	expect(reason).toBe("BootstrapTooLarge")
end)

it("rejects the previous protocol version that had no Enum references", function()
	local source: SharedNetworkingTypes.ProtocolMessage = message(ids(4), 1)
	assert(source.kind == "Bootstrap", "Expected a bootstrap message")

	local manifest: any = source.manifest
	manifest.version = 6
	expect(Constants.PROTOCOL_VERSION > 6).toBe(true)
	expect(decodeFailure(TestUtils.encode(source))).toBe("ProtocolMismatch")
end)
