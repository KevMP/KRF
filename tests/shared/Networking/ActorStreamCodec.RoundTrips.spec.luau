--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF

local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local SharedNetworkingTypes = require(KRF.shared.Networking.types)
local TestUtils = require(script.Parent.Parent.Utils.Networking.ActorStreamCodecTestUtils)

local codec: SharedNetworkingTypes.ActorStreamCodec
beforeEach(function()
	codec = TestUtils.codec()
end)

it("round-trips Begin, Chunk, End, live Commit, Halt and Remove records in one buffer", function()
	local records: { SharedNetworkingTypes.ActorStreamRecord } = {
		{ kind = "BaselineBegin", handle = 17, actorId = "ActorA", generation = 3, totalBytes = 3 },
		{ kind = "BaselineChunk", handle = 17, generation = 3, offset = 0, bytes = buffer.fromstring("abc") },
		{ kind = "BaselineEnd", handle = 17, generation = 3, revision = 10 },
		{
			kind = "Commit",
			handle = 17,
			revision = 11,
			patches = {
				{
					domainId = "Game.State",
					patch = { kind = "Struct", fields = { current = { kind = "Replace", value = 80 } } },
				},
			},
			events = { { domainId = "Game.State", eventId = "Changed", payload = { count = 2 } } },
		},
		{ kind = "ActorHalt", handle = 17 },
		{ kind = "ActorRemove", handle = 17 },
	}
	local payload: buffer = TestUtils.encode(codec, records)
	expect(typeof(payload)).toBe("buffer")
	local decoded: { SharedNetworkingTypes.ActorStreamRecord } = TestUtils.decode(codec, payload)
	expect(#decoded).toBe(#records)
	for index: number, record: SharedNetworkingTypes.ActorStreamRecord in decoded do
		if record.kind == "BaselineChunk" then
			expect(record.handle).toBe(17)
			expect(record.generation).toBe(3)
			expect(record.offset).toBe(0)
			expect(buffer.tostring(record.bytes)).toBe("abc")
		else
			expect(record).toEqual(records[index])
		end
	end
end)

it("preserves Struct field patches, Optional removals, Map entry replacement/removal and Array order", function()
	local patch: SharedNetworkingTypes.ActorPatch = {
		kind = "Struct",
		fields = {
			current = { kind = "Replace", value = 0 },
			target = { kind = "Replace", value = nil },
			items = { kind = "Map", entries = { Potion = 2 }, removed = { "Sword" } },
			order = { kind = "Replace", value = { 3, 1, 2 } },
		},
	}
	local records: { SharedNetworkingTypes.ActorStreamRecord } = {
		{
			kind = "Commit",
			handle = 1,
			revision = 2,
			patches = { { domainId = "Game.State", patch = patch } },
			events = {},
		},
	}
	expect(TestUtils.decode(codec, TestUtils.encode(codec, records))).toEqual(records)
end)

it("preserves a present domain whose top-level Optional truth is nil", function()
	local domains: { [string]: SharedNetworkingTypes.ActorDomainTruth } = { ["Game.Optional"] = { value = nil } }
	local payload: buffer?, reason: string? = codec.EncodeBaseline(domains)
	expect(reason).toBeNil()
	assert(payload ~= nil, "Expected Optional baseline")
	local decoded: { [string]: SharedNetworkingTypes.ActorDomainTruth }?, decodeReason: string? =
		codec.DecodeBaseline(payload)
	expect(decodeReason).toBeNil()
	expect(decoded).toEqual(domains)
end)

it("preserves an empty visible domain set for an aware Actor", function()
	local payload: buffer?, reason: string? = codec.EncodeBaseline({})
	expect(reason).toBeNil()
	assert(payload ~= nil, "Expected empty visible baseline")
	local decoded: { [string]: SharedNetworkingTypes.ActorDomainTruth }?, decodeReason: string? =
		codec.DecodeBaseline(payload)
	expect(decodeReason).toBeNil()
	expect(decoded).toEqual({})
end)

it("round-trips baseline truth without encoding friendly domain ids or Struct field names", function()
	local domains: { [string]: SharedNetworkingTypes.ActorDomainTruth } = {
		["Game.State"] = {
			value = {
				current = 80,
				target = "Enemy",
				items = { Potion = 2 },
				order = { 2, 1 },
			},
		},
		["Game.Optional"] = { value = 7 },
	}
	local payload: buffer?, reason: string? = codec.EncodeBaseline(domains)
	expect(reason).toBeNil()
	assert(payload ~= nil, "Expected encoded baseline truth")
	local bytes: string = buffer.tostring(payload)
	for _, name: string in { "Game.State", "Game.Optional", "current", "target", "items", "order" } do
		local position: number? = string.find(bytes, name, 1, true)
		expect(position).toBeNil()
	end
	local decoded: { [string]: SharedNetworkingTypes.ActorDomainTruth }?, decodeReason: string? =
		codec.DecodeBaseline(payload)
	expect(decodeReason).toBeNil()
	expect(decoded).toEqual(domains)
end)

it("round-trips full state replacement separately from schema-aware partial patches", function()
	local records: { SharedNetworkingTypes.ActorStreamRecord } = {
		{
			kind = "Commit",
			handle = 1,
			revision = 2,
			patches = {
				{
					domainId = "Game.State",
					patch = {
						kind = "Replace",
						value = {
							current = 100,
							target = "Enemy",
							items = { Potion = 2 },
							order = { 2, 1 },
						},
					},
				},
			},
			events = {},
		},
	}
	expect(TestUtils.decode(codec, TestUtils.encode(codec, records))).toEqual(records)
end)

it("uses handles and codebooks without resending actorId, domain names, fields or event names in live bytes", function()
	local records: { SharedNetworkingTypes.ActorStreamRecord } = {
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
			events = { { domainId = "Game.State", eventId = "Changed", payload = { count = 1 } } },
		},
	}
	local payload: buffer = TestUtils.encode(codec, records)
	local bytes: string = buffer.tostring(payload)
	for _, name: string in { "ActorA", "Game.State", "current", "Changed", "count" } do
		expect(string.find(bytes, name, 1, true)).toBeNil()
	end
	expect(TestUtils.decode(codec, payload)).toEqual(records)
end)

it("preserves each Actor's logical record order when physical packets batch Actors", function()
	local records: { SharedNetworkingTypes.ActorStreamRecord } = {
		{ kind = "Commit", handle = 1, revision = 2, patches = {}, events = {} },
		{ kind = "Commit", handle = 2, revision = 7, patches = {}, events = {} },
		{ kind = "Commit", handle = 1, revision = 3, patches = {}, events = {} },
		{ kind = "ActorRemove", handle = 2 },
	}
	expect(TestUtils.decode(codec, TestUtils.encode(codec, records))).toEqual(records)
end)

it("encodes identity on initial Begin and omits it from a replacement Begin for the same handle", function()
	local initial: { SharedNetworkingTypes.ActorStreamRecord } = {
		{ kind = "BaselineBegin", handle = 17, actorId = "IdentityOnlyInFirstBegin", generation = 1, totalBytes = 3 },
	}
	local replacement: { SharedNetworkingTypes.ActorStreamRecord } = {
		{ kind = "BaselineBegin", handle = 17, generation = 2, totalBytes = 3 },
	}
	local initialBytes: buffer = TestUtils.encode(codec, initial)
	local replacementBytes: buffer = TestUtils.encode(codec, replacement)
	expect(TestUtils.decode(codec, initialBytes)).toEqual(initial)
	expect(TestUtils.decode(codec, replacementBytes)).toEqual(replacement)
	local initialIdentity: number? = string.find(buffer.tostring(initialBytes), "IdentityOnlyInFirstBegin", 1, true)
	local replacementIdentity: number? =
		string.find(buffer.tostring(replacementBytes), "IdentityOnlyInFirstBegin", 1, true)
	expect(initialIdentity).never.toBeNil()
	expect(replacementIdentity).toBeNil()
	expect(buffer.len(replacementBytes) < buffer.len(initialBytes)).toBe(true)
end)
