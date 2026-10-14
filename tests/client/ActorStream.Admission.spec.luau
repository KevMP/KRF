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

it("rejects a Begin beyond maxPendingBaselines and frees the slot after completion", function()
	fixture.options.maxPendingBaselines = 1
	local runtime: Types.Runtime = TestUtils.start(fixture)
	local body: buffer = TestUtils.body(fixture)
	expect(TestUtils.send(fixture, {
		{ kind = "BaselineBegin", handle = 1, actorId = "ActorA", generation = 1, totalBytes = buffer.len(body) },
	})).toBe(true)
	local original: Types.ActorRecord? = runtime:GetByHandle(1)
	local success: boolean, reason: string? = TestUtils.send(fixture, {
		{ kind = "BaselineBegin", handle = 2, actorId = "ActorB", generation = 1, totalBytes = buffer.len(body) },
	})
	expect(success).toBe(false)
	expect(reason).toBe("PendingBaselineLimit")
	expect(runtime:GetByHandle(2)).toBeNil()
	expect(runtime:GetByActorId("ActorB")).toBeNil()
	expect(runtime:GetByHandle(1)).toBe(original)
	expect(fixture.baselines).toEqual({})
	expect(TestUtils.send(fixture, {
		{ kind = "BaselineChunk", handle = 1, generation = 1, offset = 0, bytes = body },
		{ kind = "BaselineEnd", handle = 1, generation = 1, revision = 1 },
	})).toBe(true)
	TestUtils.establish(fixture, 2, "ActorB")
	expect(#fixture.baselines).toBe(2)
	expect(fixture.baselines[2].actor.actorId).toBe("ActorB")
end)

it("replaces an incomplete generation at the pending limit without charging a second slot", function()
	fixture.options.maxPendingBaselines = 1
	TestUtils.start(fixture)
	local body: buffer = TestUtils.body(fixture)
	expect(TestUtils.send(fixture, {
		{ kind = "BaselineBegin", handle = 1, actorId = "ActorA", generation = 1, totalBytes = buffer.len(body) },
		{ kind = "BaselineBegin", handle = 1, actorId = "ActorA", generation = 2, totalBytes = buffer.len(body) },
	})).toBe(true)
	local success: boolean, reason: string? = TestUtils.send(fixture, {
		{ kind = "BaselineBegin", handle = 2, actorId = "ActorB", generation = 1, totalBytes = buffer.len(body) },
	})
	expect(success).toBe(false)
	expect(reason).toBe("PendingBaselineLimit")
	expect(TestUtils.send(fixture, {
		{ kind = "BaselineChunk", handle = 1, generation = 2, offset = 0, bytes = body },
		{ kind = "BaselineEnd", handle = 1, generation = 2, revision = 2 },
	})).toBe(true)
	TestUtils.establish(fixture, 2, "ActorB")
	expect(#fixture.baselines).toBe(2)
end)

it("releases an incomplete assembly slot on ActorRemove while keeping its handle retired", function()
	fixture.options.maxPendingBaselines = 1
	local runtime: Types.Runtime = TestUtils.start(fixture)
	local body: buffer = TestUtils.body(fixture)
	expect(TestUtils.send(fixture, {
		{ kind = "BaselineBegin", handle = 1, actorId = "ActorA", generation = 1, totalBytes = buffer.len(body) },
		{ kind = "ActorRemove", handle = 1 },
	})).toBe(true)
	TestUtils.establish(fixture, 2, "ActorB")
	expect(runtime:GetByHandle(1)).toBeNil()
	expect(#fixture.baselines).toBe(1)
	expect(fixture.baselines[1].actor.actorId).toBe("ActorB")
	local success: boolean, reason: string? = TestUtils.send(fixture, {
		{ kind = "BaselineBegin", handle = 1, actorId = "ActorC", generation = 2, totalBytes = buffer.len(body) },
	})
	expect(success).toBe(false)
	expect(reason).toBe("RetiredActorHandle")
end)

it("does not consume pending capacity for an oversized rejected Begin", function()
	fixture.options.maxPendingBaselines = 1
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
	TestUtils.establish(fixture, 2, "ActorB")
	expect(runtime:GetByHandle(1)).toBeNil()
	expect(#fixture.baselines).toBe(1)
end)

for _, generation: number in { 2, 3 } do
	it(
		"rejects Begin generation "
			.. tostring(generation)
			.. " after completed generation 3 and accepts a newer attempt",
		function()
			local runtime: Types.Runtime = TestUtils.start(fixture)
			TestUtils.establish(fixture, 1, "ActorA", 3, 7)
			local original: Types.ActorRecord? = runtime:GetByHandle(1)
			local body: buffer = TestUtils.body(fixture)
			local success: boolean, reason: string? = TestUtils.send(fixture, {
				{
					kind = "BaselineBegin",
					handle = 1,
					actorId = "ActorA",
					generation = generation,
					totalBytes = buffer.len(body),
				},
			})
			expect(success).toBe(false)
			expect(reason).toBe("StaleBaselineGeneration")
			expect(runtime:GetByHandle(1)).toBe(original)
			expect(#fixture.baselines).toBe(1)
			expect(fixture.baselines[1].revision).toBe(7)
			TestUtils.establish(fixture, 1, "ActorA", 4, 10)
			expect(runtime:GetByHandle(1)).toBe(original)
			expect(#fixture.baselines).toBe(2)
			expect(fixture.baselines[2].revision).toBe(10)
		end
	)
end
