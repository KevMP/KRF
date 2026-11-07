--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF

local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local ActionRequestTypes = require(KRF.shared.ActionRequest.types)
local SharedNetworkingTypes = require(KRF.shared.Networking.types)
local Schema: SharedNetworkingTypes.Schema = require(KRF.shared.Networking.Schema)

local PayloadCodec: ActionRequestTypes.ActionPayloadCodecModule =
	require(KRF.shared.ActionRequest.utils.ActionPayloadCodec)

local TestUtils = require(script.Parent.Parent.Utils.ActionRequestTestUtils)

local schemas: ActionRequestTypes.ActionRequestSchemas = {
	["Game.Typed"] = {
		start = Schema.Struct({ label = Schema.String(16), power = Schema.U8 }),
		stop = { parameters = Schema.Struct({ charge = Schema.U16 }) },
		allowInputInterrupt = true,
	},
	["Game.Plain"] = { stop = {} },
	["Game.Large"] = { start = Schema.String(8184) },
}

-- Compile inside each test so a missing compiler fails the behavior, not suite loading.
local function startOf(actionId: string): ActionRequestTypes.CompiledActionPayload
	return TestUtils.request(TestUtils.compile(schemas), actionId).start
end

local function stopOf(actionId: string): ActionRequestTypes.CompiledActionPayload
	local stop: ActionRequestTypes.CompiledActionPayload? = TestUtils.request(TestUtils.compile(schemas), actionId).stop
	assert(stop ~= nil, "Expected a declared Stop path for " .. actionId)

	return stop
end

local function encode(payload: ActionRequestTypes.CompiledActionPayload, value: any): string
	local encoded: string?, reason: string? = PayloadCodec.Encode(payload, value)
	expect(reason).toBeNil()
	assert(encoded ~= nil, "Expected an encoded inner payload")

	return encoded
end

local function expectDecodeFailure(payload: ActionRequestTypes.CompiledActionPayload, encoded: any, reason: string): ()
	local decoded: boolean, value: any, failure: string? = PayloadCodec.Decode(payload, encoded)
	expect(decoded).toBe(false)
	expect(value).toBeNil()
	expect(failure).toBe(reason)
end

it("encodes a typed Start into a bounded binary string that decodes to an owned equal value", function()
	local start: ActionRequestTypes.CompiledActionPayload = startOf("Game.Typed")
	local parameters: any = { label = "fire", power = 200 }
	local encoded: string = encode(start, parameters)
	expect(type(encoded)).toBe("string")
	expect(#encoded > 0 and #encoded <= 8192).toBe(true)

	local decoded: boolean, value: any, reason: string? = PayloadCodec.Decode(start, encoded)
	expect(reason).toBeNil()
	expect(decoded).toBe(true)
	expect(value).toEqual(parameters)
	expect(value).never.toBe(parameters)
end)

it("round-trips typed Stop parameters with the Action's own Stop codec", function()
	local stop: ActionRequestTypes.CompiledActionPayload = stopOf("Game.Typed")
	local decoded: boolean, value: any = PayloadCodec.Decode(stop, encode(stop, { charge = 65535 }))
	expect(decoded).toBe(true)
	expect(value).toEqual({ charge = 65535 })
end)

it("round-trips binary strings containing NUL and high bytes without truncation", function()
	local start: ActionRequestTypes.CompiledActionPayload = startOf("Game.Typed")
	local label: string = "a\0b\255\0"
	local decoded: boolean, value: any = PayloadCodec.Decode(start, encode(start, { label = label, power = 1 }))
	expect(decoded).toBe(true)
	expect(value.label).toBe(label)
	expect(#value.label).toBe(5)
end)

it("represents parameterless Start and Stop as an empty inner payload", function()
	local start: ActionRequestTypes.CompiledActionPayload = startOf("Game.Plain")
	expect(encode(start, nil)).toBe("")
	expect(encode(stopOf("Game.Plain"), nil)).toBe("")

	local decoded: boolean, value: any, reason: string? = PayloadCodec.Decode(start, "")
	expect(reason).toBeNil()
	expect(decoded).toBe(true)
	expect(value).toBeNil()
end)

it("encodes a payload at exactly the 8192 byte inner bound", function()
	local start: ActionRequestTypes.CompiledActionPayload = startOf("Game.Large")
	local encoded: string = encode(start, string.rep("x", 8184))
	expect(#encoded <= 8192).toBe(true)
	local decoded: boolean, value: any = PayloadCodec.Decode(start, encoded)
	expect(decoded).toBe(true)
	expect(#value).toBe(8184)
end)

type EncodeFailure = { label: string, actionId: string, value: any, reason: string }

local encodeFailures: { EncodeFailure } = {
	{
		label = "a mistyped field",
		actionId = "Game.Typed",
		value = { label = "x", power = "high" },
		reason = "ActionPayloadInvalid",
	},
	{ label = "a missing field", actionId = "Game.Typed", value = { label = "x" }, reason = "ActionPayloadInvalid" },
	{
		label = "an extra field",
		actionId = "Game.Typed",
		value = { label = "x", power = 1, target = "Boss" },
		reason = "ActionPayloadInvalid",
	},
	{
		label = "an out-of-range integer",
		actionId = "Game.Typed",
		value = { label = "x", power = 256 },
		reason = "ActionPayloadInvalid",
	},
	{
		label = "an oversized string",
		actionId = "Game.Typed",
		value = { label = string.rep("x", 17), power = 1 },
		reason = "ActionPayloadInvalid",
	},
	{ label = "a function value", actionId = "Game.Typed", value = function() end, reason = "ActionPayloadInvalid" },
	{
		label = "parameters for a parameterless payload",
		actionId = "Game.Plain",
		value = { power = 1 },
		reason = "ActionPayloadUnexpected",
	},
}

for _, failure: EncodeFailure in encodeFailures do
	it("rejects " .. failure.label .. " locally before producing any wire payload", function()
		local encoded: string?, reason: string? = PayloadCodec.Encode(startOf(failure.actionId), failure.value)
		expect(encoded).toBeNil()
		expect(reason).toBe(failure.reason)
	end)
end

it("does not retain or observe caller tables mutated after encoding", function()
	local start: ActionRequestTypes.CompiledActionPayload = startOf("Game.Typed")
	local parameters: any = { label = "frozen", power = 7 }
	local encoded: string = encode(start, parameters)

	parameters.power = 99
	parameters.label = "mutated"
	local decoded: boolean, value: any = PayloadCodec.Decode(start, encoded)
	expect(decoded).toBe(true)
	expect(value).toEqual({ label = "frozen", power = 7 })
end)

it("rejects a non-string inner payload", function()
	local start: ActionRequestTypes.CompiledActionPayload = startOf("Game.Typed")
	expectDecodeFailure(start, buffer.create(2), "ActionPayloadMalformed")
	expectDecodeFailure(start, 12, "ActionPayloadMalformed")
	expectDecodeFailure(start, nil, "ActionPayloadMalformed")
end)

it("rejects truncated typed bytes before any decoded value escapes", function()
	local start: ActionRequestTypes.CompiledActionPayload = startOf("Game.Typed")
	local encoded: string = encode(start, { label = "truncate", power = 1 })
	expectDecodeFailure(start, string.sub(encoded, 1, #encoded - 1), "ActionPayloadMalformed")
	expectDecodeFailure(start, "", "ActionPayloadMalformed")
end)

it("rejects trailing bytes after a complete typed value", function()
	local start: ActionRequestTypes.CompiledActionPayload = startOf("Game.Typed")
	expectDecodeFailure(start, encode(start, { label = "tail", power = 1 }) .. "\0", "ActionPayloadTrailingBytes")
end)

it("rejects any bytes for a parameterless payload", function()
	expectDecodeFailure(startOf("Game.Plain"), "\0", "ActionPayloadTrailingBytes")
end)

it("rejects a payload over the 8192 byte inner bound without decoding it", function()
	expectDecodeFailure(startOf("Game.Large"), string.rep("\255", 8193), "ActionPayloadTooLarge")
end)

it("rejects bytes encoded for one Action's Start when decoded with its Stop schema", function()
	local encoded: string = encode(startOf("Game.Typed"), { label = "wrong", power = 3 })
	local decoded: boolean = PayloadCodec.Decode(stopOf("Game.Typed"), encoded)
	expect(decoded).toBe(false)
end)
