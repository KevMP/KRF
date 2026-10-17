--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local Codec = require(KRF.shared.Networking.utils.ResyncCodec)
local ProtocolUtils = require(script.Parent.Parent.Utils.Networking.ProtocolTestUtils)
local ActorUtils = require(script.Parent.Parent.Utils.Networking.ActorStreamCodecTestUtils)

for _, handle: number in { 1, 255, 65536, 4294967295 } do
	it("round-trips a compact private buffer request for handle " .. tostring(handle), function()
		local payload: buffer?, reason: string? = Codec.Encode(handle)
		expect(reason).toBeNil()
		assert(payload ~= nil, "Expected encoded recovery control request")
		expect(typeof(payload)).toBe("buffer")
		expect(buffer.len(payload) <= 16).toBe(true)
		local request: Codec.Request?
		request, reason = Codec.Decode(payload)
		expect(reason).toBeNil()
		expect(request).toEqual({ handle = handle })
	end)
end

for _, handle: number in { 0, -1, 0.5, 4294967296, math.huge, 0 / 0 } do
	it("rejects invalid control handle " .. tostring(handle), function()
		local payload: buffer?, reason: string? = Codec.Encode(handle)
		expect(payload).toBeNil()
		expect(reason).toBe("InvalidActorHandle")
	end)
end

for _, payload: any in { false, 1, "RESYNC_REQUEST", {}, { handle = 1 }, buffer.create(0) } do
	it("rejects non-framed control input of type " .. typeof(payload), function()
		local request: Codec.Request?, reason: string? = Codec.Decode(payload)
		expect(request).toBeNil()
		expect(reason).toBe("MalformedResyncRequest")
	end)
end

it("rejects nil control input", function()
	local request: Codec.Request?, reason: string? = Codec.Decode(nil)
	expect(request).toBeNil()
	expect(reason).toBe("MalformedResyncRequest")
end)

it("rejects every truncated request and trailing bytes without choosing a public wire layout", function()
	local payload: buffer?, reason: string? = Codec.Encode(1)
	assert(payload ~= nil, reason)
	for length: number = 0, buffer.len(payload) - 1 do
		local truncated: buffer = buffer.create(length)
		buffer.copy(truncated, 0, payload, 0, length)
		local request: Codec.Request?
		request, reason = Codec.Decode(truncated)
		expect(request).toBeNil()
		expect(reason).toBe("MalformedResyncRequest")
	end
	local extra: buffer = buffer.create(buffer.len(payload) + 1)
	buffer.copy(extra, 0, payload)
	local request: Codec.Request?
	request, reason = Codec.Decode(extra)
	expect(request).toBeNil()
	expect(reason).toBe("MalformedResyncRequest")
end)

it("cannot confuse bootstrap or server Actor traffic with a resync request", function()
	local payloads: { buffer } = {
		ProtocolUtils.encode({ kind = "Ready" }),
		ActorUtils.encode(ActorUtils.codec(), { { kind = "ActorRemove", handle = 1 } }),
	}
	for _, payload: buffer in payloads do
		local request: Codec.Request?, reason: string? = Codec.Decode(payload)
		expect(request).toBeNil()
		expect(reason).toBe("MalformedResyncRequest")
	end
end)
