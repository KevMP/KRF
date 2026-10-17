--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local PublicTypes = require(KRF.client.Actor.types)
local TestUtils = require(script.Parent.Utils.ActorViewTestUtils)
local StreamUtils = require(script.Parent.Utils.ActorStreamTestUtils)

local fixture: TestUtils.Fixture
beforeEach(function()
	fixture = TestUtils.new()
end)
afterEach(function()
	TestUtils.destroy(fixture)
end)

it("recovers a corrupt complete Actor baseline without dropping another Actor's valid packet record", function()
	TestUtils.baseline(fixture)
	TestUtils.baseline(fixture, 2, "ActorB")
	local domain: PublicTypes.DomainView = TestUtils.domain(fixture)
	local invalid: buffer = buffer.fromstring("invalid")
	local accepted: boolean, reason: string? = StreamUtils.send(fixture.stream, {
		{ kind = "BaselineBegin", handle = 1, generation = 2, totalBytes = buffer.len(invalid) },
		{ kind = "BaselineChunk", handle = 1, generation = 2, offset = 0, bytes = invalid },
		{ kind = "BaselineEnd", handle = 1, generation = 2, revision = 20 },
		{ kind = "Commit", handle = 2, revision = 11, patches = { TestUtils.patch(60) }, events = {} },
	})
	expect(accepted).toBe(false)
	expect(reason).toBe("InvalidActorBaseline")
	expect(fixture.stream.faults).toEqual({ "InvalidActorBaseline" })
	expect(domain:GetState().current).toBe(100)
	expect(#fixture.requests).toBe(1)
	expect(TestUtils.domain(fixture, nil, "ActorB"):GetState().current).toBe(60)
	TestUtils.baseline(fixture, 1, nil, 30, TestUtils.truth(50), 3)
	expect(TestUtils.domain(fixture)).toBe(domain)
	expect(domain:GetState().current).toBe(50)
	TestUtils.advance(fixture, 100)
	expect(#fixture.requests).toBe(1)
end)

it("releases invalid completed assembly before recovery can deliver a replacement synchronously", function()
	TestUtils.destroy(fixture)
	fixture = TestUtils.new(function(_payload: buffer)
		TestUtils.baseline(fixture, 1, nil, 30, TestUtils.truth(50), 3)
	end)
	fixture.stream.options.maxPendingBaselines = 1
	TestUtils.baseline(fixture)
	local accepted: boolean, reason: string? = StreamUtils.send(fixture.stream, {
		{ kind = "BaselineBegin", handle = 1, generation = 2, totalBytes = 1 },
		{ kind = "BaselineChunk", handle = 1, generation = 2, offset = 0, bytes = buffer.fromstring("x") },
		{ kind = "BaselineEnd", handle = 1, generation = 2, revision = 20 },
	})
	expect(accepted).toBe(false)
	expect(reason).toBe("InvalidActorBaseline")
	expect(TestUtils.domain(fixture):GetState().current).toBe(50)
	expect(#fixture.requests).toBe(1)
	TestUtils.baseline(fixture, 2, "ActorB")
	expect(TestUtils.view(fixture, "ActorB"):IsAvailable()).toBe(true)
end)

it("preserves valid in-progress assembly after a rejected overlapping chunk while recovery waits", function()
	TestUtils.baseline(fixture)
	local body: buffer?, reason: string? = fixture.stream.codec.EncodeBaseline(TestUtils.truth(50))
	assert(body ~= nil, reason)
	TestUtils.send(fixture, {
		{ kind = "BaselineBegin", handle = 1, generation = 2, totalBytes = buffer.len(body) },
		{ kind = "BaselineChunk", handle = 1, generation = 2, offset = 0, bytes = body },
	})
	local accepted: boolean
	accepted, reason = StreamUtils.send(fixture.stream, {
		{ kind = "BaselineChunk", handle = 1, generation = 2, offset = 0, bytes = body },
	})
	expect(accepted).toBe(false)
	expect(reason).toBe("BaselineChunkOverlap")
	expect(#fixture.requests).toBe(1)
	TestUtils.send(fixture, { { kind = "BaselineEnd", handle = 1, generation = 2, revision = 20 } })
	expect(TestUtils.domain(fixture):GetState().current).toBe(50)
	TestUtils.advance(fixture, 100)
	expect(#fixture.requests).toBe(1)
end)

it("reports untrusted physical framing without guessing an Actor identity or applying partial records", function()
	TestUtils.baseline(fixture)
	local valid: buffer?, reason: string? = fixture.stream.codec.Encode({
		{ kind = "Commit", handle = 1, revision = 11, patches = { TestUtils.patch(50) }, events = {} },
	})
	assert(valid ~= nil, reason)
	local trailing: buffer = buffer.create(buffer.len(valid) + 1)
	buffer.copy(trailing, 0, valid)
	assert(fixture.stream.runtime ~= nil, "Expected decoder")
	local accepted: boolean
	accepted, reason = fixture.stream.runtime:Handle(trailing)
	expect(accepted).toBe(false)
	expect(reason).toBe("MalformedActorPacket")
	expect(fixture.stream.faults).toEqual({ "MalformedActorPacket" })
	expect(fixture.faults).toEqual({})
	expect(fixture.requests).toEqual({})
	expect(TestUtils.domain(fixture):GetState().current).toBe(100)
	TestUtils.commit(fixture, 11, { TestUtils.patch(60) })
	expect(TestUtils.domain(fixture):GetState().current).toBe(60)
end)
