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

it("passes decoded patches and events to N5 in per-Actor order without applying state", function()
	TestUtils.start(fixture)
	TestUtils.establish(fixture)
	TestUtils.establish(fixture, 2, "ActorB")
	expect(TestUtils.send(fixture, {
		{
			kind = "Commit",
			handle = 1,
			revision = 2,
			patches = {
				{
					domainId = "Game.Actions",
					patch = { kind = "Struct", fields = { active = { kind = "Replace", value = true } } },
				},
			},
			events = {},
		},
		{
			kind = "Commit",
			handle = 2,
			revision = 2,
			patches = {},
			events = { { domainId = "Game.Actions", eventId = "Changed", payload = { count = 1 } } },
		},
		{
			kind = "Commit",
			handle = 1,
			revision = 3,
			patches = {},
			events = { { domainId = "Game.Actions", eventId = "Changed", payload = { count = 2 } } },
		},
	})).toBe(true)
	expect(#fixture.commits).toBe(3)
	expect(fixture.commits[1].actor.actorId).toBe("ActorA")
	expect(fixture.commits[1].patches).toEqual({
		{
			domainId = "Game.Actions",
			patch = { kind = "Struct", fields = { active = { kind = "Replace", value = true } } },
		},
	})
	expect(fixture.commits[2].actor.actorId).toBe("ActorB")
	expect(fixture.commits[3].revision).toBe(3)
	expect(fixture.commits[3].events).toEqual({
		{ domainId = "Game.Actions", eventId = "Changed", payload = { count = 2 } },
	})
	expect(fixture.baselines[1].domains["Game.Actions"].value).toEqual({ active = false, mode = "Idle" })
end)

it("leaves revision-gap decisions to N5 and forwards a structurally valid later revision", function()
	TestUtils.start(fixture)
	TestUtils.establish(fixture)
	expect(TestUtils.send(fixture, {
		{
			kind = "Commit",
			handle = 1,
			revision = 10,
			patches = {},
			events = { { domainId = "Game.Actions", eventId = "Changed", payload = { count = 1 } } },
		},
	})).toBe(true)
	expect(#fixture.commits).toBe(1)
	expect(fixture.commits[1].revision).toBe(10)
end)

it("rejects an unknown handle without delivering records to the N5 consumer", function()
	TestUtils.start(fixture)
	local success: boolean, reason: string? =
		TestUtils.send(fixture, { { kind = "Commit", handle = 99, revision = 1, patches = {}, events = {} } })
	expect(success).toBe(false)
	expect(reason).toBe("UnknownActorHandle")
	expect(fixture.commits).toEqual({})
end)

it("removes incomplete assembly, retires the handle, and rejects delayed chunks and handle reuse", function()
	local runtime: Types.Runtime = TestUtils.start(fixture)
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
	expect(TestUtils.send(fixture, { { kind = "ActorRemove", handle = 1 } })).toBe(true)
	expect(runtime:GetByHandle(1)).toBeNil()
	expect(runtime:GetByActorId("ActorA")).toBeNil()
	expect(#fixture.removed).toBe(1)
	local success: boolean, reason: string? =
		TestUtils.send(fixture, { { kind = "BaselineChunk", handle = 1, generation = 1, offset = 0, bytes = body } })
	expect(success).toBe(false)
	expect(reason).toBe("RetiredActorHandle")
	success, reason = TestUtils.send(
		fixture,
		{ { kind = "BaselineBegin", handle = 1, actorId = "ActorB", generation = 2, totalBytes = buffer.len(body) } }
	)
	expect(success).toBe(false)
	expect(reason).toBe("RetiredActorHandle")
	expect(fixture.baselines).toEqual({})
end)

it("keeps the other Actor record intact when one Actor is removed", function()
	local runtime: Types.Runtime = TestUtils.start(fixture)
	TestUtils.establish(fixture)
	TestUtils.establish(fixture, 2, "ActorB")
	local remaining: Types.ActorRecord? = runtime:GetByHandle(2)
	expect(TestUtils.send(fixture, { { kind = "ActorRemove", handle = 1 } })).toBe(true)
	expect(runtime:GetByHandle(1)).toBeNil()
	expect(runtime:GetByHandle(2)).toBe(remaining)
	expect(#fixture.removed).toBe(1)
end)
