--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local Types = require(KRF.shared.Networking.ActorStreamTypes)
local SchemaTypes = require(KRF.shared.Networking.types)
local Schema: SchemaTypes.Schema = require(KRF.shared.Networking.Schema)
local Compiler = require(KRF.shared.Networking.utils.ActorPatchCompiler)
local Bytes = require(KRF.shared.Networking.utils.ActorBuffer)
local SchemaUtils = require(script.Parent.Parent.Utils.Networking.SchemaTestUtils)
local CodecUtils = require(script.Parent.Parent.Utils.Networking.ActorStreamCodecTestUtils)
local Codec: Types.CodecModule = require(KRF.shared.Networking.ActorStreamCodec)

local function decode(plan: Compiler.Plan, body: buffer): Types.Patch
	local cursor: Bytes.Cursor =
		{ data = body, offset = 0, limit = buffer.len(body), remaining = 100000, context = "InvalidActorPatch" }
	return plan.Read(cursor)
end

it("round-trips multiple sorted Map entries and removals without replacing unrelated entries", function()
	local plan: Compiler.Plan = Compiler.Compile(SchemaUtils.compile(Schema.Map(Schema.String(8), Schema.U8, 2)))
	local patch: Types.Patch = { kind = "Map", entries = { B = 2, A = 1 }, removed = { "C", "D" } }
	local body: buffer = Bytes.Encode(function(cursor: Bytes.Cursor)
		plan.Write(cursor, patch)
	end, 512, "InvalidActorPatch")
	expect(decode(plan, body)).toEqual(patch)
end)

it("rejects a patch operation incompatible with the admitted schema on encode and decode", function()
	local scalar: Compiler.Plan = Compiler.Compile(SchemaUtils.compile(Schema.U8))
	local map: Compiler.Plan = Compiler.Compile(SchemaUtils.compile(Schema.Map(Schema.U8, Schema.U8, 2)))
	local patch: Types.Patch = { kind = "Map", entries = { [1] = 2 }, removed = {} }
	expect(function()
		Bytes.Encode(function(cursor: Bytes.Cursor)
			scalar.Write(cursor, patch)
		end, 512, "InvalidActorPatch")
	end).toThrow("InvalidActorPatch")
	local body: buffer = Bytes.Encode(function(cursor: Bytes.Cursor)
		map.Write(cursor, patch)
	end, 512, "InvalidActorPatch")
	expect(function()
		decode(scalar, body)
	end).toThrow("InvalidActorPatch")
end)

for _, overlapping: boolean in { true, false } do
	it("rejects overlapping or duplicated Map removals with overlap=" .. tostring(overlapping), function()
		local plan: Compiler.Plan = Compiler.Compile(SchemaUtils.compile(Schema.Map(Schema.U8, Schema.U8, 2)))
		local patch: Types.Patch =
			{ kind = "Map", entries = if overlapping then { [1] = 2 } else {}, removed = { 1, 1 } }
		expect(function()
			Bytes.Encode(function(cursor: Bytes.Cursor)
				plan.Write(cursor, patch)
			end, 512, "InvalidActorPatch")
		end).toThrow("InvalidActorPatch")
	end)
end

it("rejects a foreign Map whose entry or removal count exceeds the receiving schema", function()
	local foreign: Compiler.Plan = Compiler.Compile(SchemaUtils.compile(Schema.Map(Schema.U8, Schema.U8, 3)))
	local receiving: Compiler.Plan = Compiler.Compile(SchemaUtils.compile(Schema.Map(Schema.U8, Schema.U8, 2)))
	local patches: { Types.Patch } = {
		{ kind = "Map", entries = { [1] = 1, [2] = 2, [3] = 3 }, removed = {} },
		{ kind = "Map", entries = {}, removed = { 1, 2, 3 } },
	}
	for _, patch: Types.Patch in patches do
		local body: buffer = Bytes.Encode(function(cursor: Bytes.Cursor)
			foreign.Write(cursor, patch)
		end, 512, "InvalidActorPatch")
		expect(function()
			decode(receiving, body)
		end).toThrow("InvalidActorPatch")
	end
end)

it("measures complete packets without allocating their encoded output and reports invalid input", function()
	local codec: Types.Codec = CodecUtils.codec()
	local records: { Types.Record } = {
		{ kind = "ActorRemove", handle = 1 },
		{ kind = "BaselineBegin", handle = 2, actorId = "ActorA", generation = 1, totalBytes = 4 },
	}
	local size: number?, reason: string? = codec.Measure(records)
	expect(reason).toBeNil()
	local body: buffer = CodecUtils.encode(codec, records)
	expect(size).toBe(buffer.len(body))
	size, reason = codec.Measure({ { kind = "ActorRemove", handle = 0 } })
	expect(size).toBeNil()
	expect(reason).toBe("MalformedActorPacket")
end)

it("rejects legal aggregate baseline truth above the actual hard limit before allocation", function()
	local codec: Types.Codec = Codec.Compile(CodecUtils.protocol(nil, nil, Schema.String(300000)))
	local body: buffer?, reason: string? =
		codec.EncodeBaseline({ ["Game.State"] = { value = string.rep("x", 300000) } })
	expect(body).toBeNil()
	expect(reason).toBe("ActorBaselineTooLarge")
end)
