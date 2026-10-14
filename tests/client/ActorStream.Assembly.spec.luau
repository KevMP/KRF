--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF

local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local Types = require(KRF.client.Networking.ActorStreamTypes)
local TestUtils = require(script.Parent.Utils.ActorStreamTestUtils)

local fixture: TestUtils.Fixture
beforeEach(function()
	fixture = TestUtils.new()
end)
afterEach(function()
	TestUtils.destroy(fixture)
end)

it("hands a baseline to N5 once only after all bytes and matching End arrive", function()
	local runtime: Types.Runtime = TestUtils.start(fixture)
	local body: buffer = TestUtils.body(fixture)
	local first: buffer = buffer.create(1)
	local remaining: buffer = buffer.create(buffer.len(body) - 1)
	buffer.copy(first, 0, body, 0, 1)
	buffer.copy(remaining, 0, body, 1)
	expect(TestUtils.send(fixture, {
		{
			kind = "BaselineBegin",
			handle = 1,
			actorId = "ActorA",
			generation = 1,
			totalBytes = buffer.len(body),
		},
	})).toBe(true)
	expect(
		TestUtils.send(fixture, { { kind = "BaselineChunk", handle = 1, generation = 1, offset = 0, bytes = first } })
	).toBe(true)
	expect(fixture.baselines).toEqual({})
	expect(
		TestUtils.send(
			fixture,
			{ { kind = "BaselineChunk", handle = 1, generation = 1, offset = 1, bytes = remaining } }
		)
	).toBe(true)
	expect(fixture.baselines).toEqual({})
	expect(TestUtils.send(fixture, { { kind = "BaselineEnd", handle = 1, generation = 1, revision = 7 } })).toBe(true)
	expect(#fixture.baselines).toBe(1)
	expect(fixture.baselines[1].revision).toBe(7)
	expect(fixture.baselines[1].domains).toEqual({
		["Game.Actions"] = { value = { active = false, mode = "Idle" } },
		["Game.Inventory"] = { value = { "Potion" } },
	})
	expect(fixture.baselines[1].actor).toBe(runtime:GetByActorId("ActorA"))
	expect(runtime:GetByHandle(1)).toBe(runtime:GetByActorId("ActorA"))
	local success: boolean, reason: string? =
		TestUtils.send(fixture, { { kind = "BaselineEnd", handle = 1, generation = 1, revision = 7 } })
	expect(success).toBe(false)
	expect(reason).toBe("BaselineNotPending")
	expect(#fixture.baselines).toBe(1)
end)

it("discards an incomplete older generation and cannot mix its chunks into a replacement", function()
	TestUtils.start(fixture)
	local body: buffer = TestUtils.body(fixture)
	expect(TestUtils.send(fixture, {
		{ kind = "BaselineBegin", handle = 1, actorId = "ActorA", generation = 1, totalBytes = buffer.len(body) },
		{ kind = "BaselineBegin", handle = 1, actorId = "ActorA", generation = 2, totalBytes = buffer.len(body) },
	})).toBe(true)
	local success: boolean, reason: string? =
		TestUtils.send(fixture, { { kind = "BaselineChunk", handle = 1, generation = 1, offset = 0, bytes = body } })
	expect(success).toBe(false)
	expect(reason).toBe("StaleBaselineGeneration")
	expect(fixture.baselines).toEqual({})
	expect(TestUtils.send(fixture, {
		{ kind = "BaselineChunk", handle = 1, generation = 2, offset = 0, bytes = body },
		{ kind = "BaselineEnd", handle = 1, generation = 2, revision = 9 },
	})).toBe(true)
	expect(#fixture.baselines).toBe(1)
	expect(fixture.baselines[1].revision).toBe(9)
end)

it("rejects an oversized Begin before creating awareness or consuming later work", function()
	local runtime: Types.Runtime = TestUtils.start(fixture)
	local success: boolean, reason: string? = TestUtils.send(fixture, {
		{
			kind = "BaselineBegin",
			handle = 1,
			actorId = "ActorA",
			generation = 1,
			totalBytes = fixture.options.maxBaselineBytes + 1,
		},
	})
	expect(success).toBe(false)
	expect(reason).toBe("ActorBaselineTooLarge")
	expect(runtime:GetByHandle(1)).toBeNil()
	expect(runtime:GetByActorId("ActorA")).toBeNil()
	expect(fixture.baselines).toEqual({})
end)

for _, offset: number in { 0, 1 } do
	it(
		"rejects duplicate or overlapping chunk at offset " .. tostring(offset) .. " without corrupting assembly",
		function()
			TestUtils.start(fixture)
			local body: buffer = TestUtils.body(fixture)
			expect(TestUtils.send(fixture, {
				{
					kind = "BaselineBegin",
					handle = 1,
					actorId = "ActorA",
					generation = 1,
					totalBytes = buffer.len(body),
				},
				{ kind = "BaselineChunk", handle = 1, generation = 1, offset = 0, bytes = body },
			})).toBe(true)
			local success: boolean, reason: string? = TestUtils.send(fixture, {
				{ kind = "BaselineChunk", handle = 1, generation = 1, offset = offset, bytes = buffer.fromstring("x") },
			})
			expect(success).toBe(false)
			expect(reason).toBe("BaselineChunkOverlap")
			expect(TestUtils.send(fixture, { { kind = "BaselineEnd", handle = 1, generation = 1, revision = 1 } })).toBe(
				true
			)
			expect(#fixture.baselines).toBe(1)
			expect(fixture.baselines[1].domains["Game.Actions"].value).toEqual({ active = false, mode = "Idle" })
		end
	)
end

it("rejects an out-of-bounds chunk and premature End without delivering a partial baseline", function()
	TestUtils.start(fixture)
	local body: buffer = TestUtils.body(fixture)
	expect(TestUtils.send(fixture, {
		{
			kind = "BaselineBegin",
			handle = 1,
			actorId = "ActorA",
			generation = 1,
			totalBytes = buffer.len(body),
		},
	})).toBe(true)
	local success: boolean, reason: string? = TestUtils.send(fixture, {
		{
			kind = "BaselineChunk",
			handle = 1,
			generation = 1,
			offset = buffer.len(body),
			bytes = buffer.fromstring("x"),
		},
	})
	expect(success).toBe(false)
	expect(reason).toBe("BaselineChunkOutOfBounds")
	success, reason = TestUtils.send(fixture, { { kind = "BaselineEnd", handle = 1, generation = 1, revision = 1 } })
	expect(success).toBe(false)
	expect(reason).toBe("BaselineIncomplete")
	expect(fixture.baselines).toEqual({})
end)

it("isolates incomplete assembly for several Actors in the same physical packet", function()
	TestUtils.start(fixture)
	local body: buffer = TestUtils.body(fixture)
	expect(TestUtils.send(fixture, {
		{ kind = "BaselineBegin", handle = 1, actorId = "ActorA", generation = 1, totalBytes = buffer.len(body) },
		{ kind = "BaselineBegin", handle = 2, actorId = "ActorB", generation = 1, totalBytes = buffer.len(body) },
		{ kind = "BaselineChunk", handle = 2, generation = 1, offset = 0, bytes = body },
		{ kind = "BaselineEnd", handle = 2, generation = 1, revision = 1 },
	})).toBe(true)
	expect(#fixture.baselines).toBe(1)
	expect(fixture.baselines[1].actor.actorId).toBe("ActorB")
	expect(TestUtils.send(fixture, {
		{ kind = "BaselineChunk", handle = 1, generation = 1, offset = 0, bytes = body },
		{ kind = "BaselineEnd", handle = 1, generation = 1, revision = 1 },
	})).toBe(true)
	expect(fixture.baselines[2].actor.actorId).toBe("ActorA")
end)

it("fails observably with no N5 consumer instead of buffering decoded history", function()
	local runtime: Types.Runtime = TestUtils.start(fixture, true)
	local success: boolean, reason: string? = TestUtils.send(fixture, { { kind = "ActorRemove", handle = 1 } })
	expect(success).toBe(false)
	expect(reason).toBe("ActorStreamConsumerMissing")
	expect(fixture.faults).toEqual({ "ActorStreamConsumerMissing" })
	expect(runtime:GetByHandle(1)).toBeNil()
end)

it("rejects a conflicting actorId on an established handle while preserving the original record", function()
	local runtime: Types.Runtime = TestUtils.start(fixture)
	TestUtils.establish(fixture)
	local original: Types.ActorRecord? = runtime:GetByHandle(1)
	local body: buffer = TestUtils.body(fixture)
	local success: boolean, reason: string? = TestUtils.send(fixture, {
		{ kind = "BaselineBegin", handle = 1, actorId = "ActorB", generation = 2, totalBytes = buffer.len(body) },
	})
	expect(success).toBe(false)
	expect(reason).toBe("ActorHandleConflict")
	expect(runtime:GetByHandle(1)).toBe(original)
	expect(runtime:GetByActorId("ActorA")).toBe(original)
	expect(runtime:GetByActorId("ActorB")).toBeNil()
	expect(#fixture.baselines).toBe(1)
end)

it("rejects a second handle for an actorId already known to the connection", function()
	local runtime: Types.Runtime = TestUtils.start(fixture)
	TestUtils.establish(fixture)
	local original: Types.ActorRecord? = runtime:GetByHandle(1)
	local body: buffer = TestUtils.body(fixture)
	local success: boolean, reason: string? = TestUtils.send(fixture, {
		{ kind = "BaselineBegin", handle = 2, actorId = "ActorA", generation = 1, totalBytes = buffer.len(body) },
	})
	expect(success).toBe(false)
	expect(reason).toBe("ActorIdConflict")
	expect(runtime:GetByHandle(2)).toBeNil()
	expect(runtime:GetByActorId("ActorA")).toBe(original)
end)
