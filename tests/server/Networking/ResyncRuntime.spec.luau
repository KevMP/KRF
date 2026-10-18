--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local Codec = require(KRF.shared.Networking.utils.ResyncCodec)
local TestUtils = require(script.Parent.Parent.Utils.Networking.ResyncTestUtils)

local fixture: TestUtils.Fixture
local player: Player
beforeEach(function()
	fixture = TestUtils.new()
	player = TestUtils.player(fixture)
end)
afterEach(function()
	TestUtils.destroy(fixture)
end)

it("admits a valid Ready-client control request through the N4 replacement seam", function()
	local success: boolean, reason: string? = TestUtils.request(fixture, player, 1)
	expect(success).toBe(true)
	expect(reason).toBeNil()
	expect(fixture.calls).toEqual({ { player = player, handle = 1 } })
	expect(fixture.pending[player][1]).toBe(true)
end)

it("rejects non-Ready clients without invoking replacement capture", function()
	fixture.ready[player] = nil
	local success: boolean, reason: string? = TestUtils.request(fixture, player, 1)
	expect(success).toBe(false)
	expect(reason).toBe("ClientNotReady")
	expect(fixture.calls).toEqual({})
end)

it("rejects an unknown handle without installing pending replacement state", function()
	local success: boolean, reason: string? = TestUtils.request(fixture, player, 99)
	expect(success).toBe(false)
	expect(reason).toBe("UnknownActorHandle")
	expect(fixture.pending[player]).toEqual({})
end)

it("does not authorize a handle belonging only to another connection", function()
	local other: Player = TestUtils.player(fixture)
	fixture.known[player][1] = nil
	local success: boolean, reason: string? = TestUtils.request(fixture, player, 1)
	expect(success).toBe(false)
	expect(reason).toBe("UnknownActorHandle")
	expect(fixture.pending[other]).toEqual({})
	success, reason = TestUtils.request(fixture, other, 1)
	expect(success).toBe(true)
	expect(reason).toBeNil()
end)

it("deduplicates an already-pending baseline without creating another replacement", function()
	expect(TestUtils.request(fixture, player, 1)).toBe(true)
	local success: boolean, reason: string? = TestUtils.request(fixture, player, 1)
	expect(success).toBe(false)
	expect(reason).toBe("BaselineAlreadyPending")
	expect(fixture.pending[player]).toEqual({ [1] = true })
end)

it("enforces the exact per-Actor window bound even when each baseline completes immediately", function()
	for _ = 1, fixture.options.maxRequestsPerActor do
		expect(TestUtils.request(fixture, player, 1)).toBe(true)
		fixture.pending[player][1] = nil
	end
	local success: boolean, reason: string? = TestUtils.request(fixture, player, 1)
	expect(success).toBe(false)
	expect(reason).toBe("ResyncRateLimited")
	expect(#fixture.calls).toBe(2)
	expect(TestUtils.request(fixture, player, 2)).toBe(true)
end)

it("enforces the per-client window bound across distinct Actors and isolates another client's allowance", function()
	for handle: number = 1, fixture.options.maxRequestsPerClient do
		expect(TestUtils.request(fixture, player, handle)).toBe(true)
	end
	local success: boolean, reason: string? = TestUtils.request(fixture, player, 5)
	expect(success).toBe(false)
	expect(reason).toBe("ResyncRateLimited")
	expect(#fixture.calls).toBe(4)
	local other: Player = TestUtils.player(fixture)
	expect(TestUtils.request(fixture, other, 5)).toBe(true)
end)

it("bounds repeated unknown-handle traffic before it can generate unbounded replacement work", function()
	for handle: number = 100, 355 do
		TestUtils.request(fixture, player, handle)
	end
	expect(#fixture.calls <= fixture.options.maxRequestsPerClient).toBe(true)
	expect(fixture.pending[player]).toEqual({})
end)

it("does not spend the per-Actor allowance of a second Actor when the first is rate-limited", function()
	for _ = 1, 2 do
		expect(TestUtils.request(fixture, player, 1)).toBe(true)
		fixture.pending[player][1] = nil
	end
	TestUtils.request(fixture, player, 1)
	expect(TestUtils.request(fixture, player, 2)).toBe(true)
end)

it("restores admission at the window boundary without a frame driver or a timer", function()
	for _ = 1, 2 do
		expect(TestUtils.request(fixture, player, 1)).toBe(true)
		fixture.pending[player][1] = nil
	end
	fixture.now = 109.999
	local success: boolean, reason: string? = TestUtils.request(fixture, player, 1)
	expect(success).toBe(false)
	expect(reason).toBe("ResyncRateLimited")
	fixture.now = 110
	success, reason = TestUtils.request(fixture, player, 1)
	expect(success).toBe(true)
	expect(reason).toBeNil()
end)

it("clears per-client recovery accounting on Closed and releases its observer on Destroy", function()
	for _ = 1, 2 do
		expect(TestUtils.request(fixture, player, 1)).toBe(true)
		fixture.pending[player][1] = nil
	end
	expect(#fixture.closed).toBe(1)
	fixture.closed[1](player)
	expect(TestUtils.request(fixture, player, 1)).toBe(true)
	local staleClosed: (Player) -> () = fixture.closed[1]
	fixture.runtime:Destroy()
	fixture.runtime:Destroy()
	staleClosed(player)
	expect(fixture.closed).toEqual({})
	local calls: number = #fixture.calls
	local success: boolean, reason: string? = TestUtils.request(fixture, player, 2)
	expect(success).toBe(false)
	expect(reason).toBe("ResyncRuntimeDestroyed")
	expect(#fixture.calls).toBe(calls)
end)

it("rejects extra remote arguments rather than accepting a buffer with side-channel payloads", function()
	local payload: buffer?, encodeReason: string? = Codec.Encode(1)
	assert(payload ~= nil, encodeReason)
	local success: boolean, reason: string? = fixture.runtime:Handle(player, payload, {})
	expect(success).toBe(false)
	expect(reason).toBe("MalformedResyncRequest")
	expect(fixture.calls).toEqual({})
end)

it("rejects malformed payloads without invoking the N4 seam", function()
	local success: boolean, reason: string? = fixture.runtime:Handle(player, { handle = 1 })
	expect(success).toBe(false)
	expect(reason).toBe("MalformedResyncRequest")
	expect(fixture.calls).toEqual({})
end)
