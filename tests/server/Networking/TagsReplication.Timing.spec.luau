--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local TagTypes = require(KRF.server.Tags.types)
local ActorTypes = require(KRF.server.Actor.types)
local ActorEntity = require(KRF.server.Actor.ActorEntity)
local TagController = require(KRF.server.Tags.TagController)
local TestUtils = require(script.Parent.Parent.Utils.Networking.TagsReplicationTestUtils)

local fixture: TestUtils.Fixture
local otherFixture: TestUtils.Fixture? = nil

beforeEach(function()
	fixture = TestUtils.new()
end)

afterEach(function()
	if otherFixture ~= nil then
		TestUtils.destroy(otherFixture)
		otherFixture = nil
	end

	TestUtils.destroy(fixture)
end)

it("keeps the initial timing anchor through repeated countdown steps and snapshot reads without committing", function()
	TestUtils.add(fixture, "Status.Burning")
	TestUtils.observe(fixture)
	local expected = { ["Status.Burning"] = { stackCount = 1, expiresAt = 1010 } }
	expect(TestUtils.snapshot(fixture)).toEqual(expected)
	local clockReads: number = fixture.clock.reads

	for _ = 1, 20 do
		TestUtils.step(fixture, 0.125)
		-- Real synchronized-clock samples and Tag stepping need not line up exactly.
		fixture.clock.now += 0.001
		expect(TestUtils.snapshot(fixture)).toEqual(expected)
	end

	expect(fixture.clock.reads).toBe(clockReads)
	expect(fixture.commits).toEqual({})
end)

it("retains untouched anchors exactly when an unrelated visible Tag mutates after clock drift", function()
	TestUtils.add(fixture, "Status.Burning")
	TestUtils.observe(fixture)
	expect(TestUtils.snapshot(fixture)).toEqual({ ["Status.Burning"] = { stackCount = 1, expiresAt = 1010 } })
	TestUtils.step(fixture, 2)
	fixture.clock.now += 0.125
	TestUtils.add(fixture, "Buff.Stack", 3)

	expect(fixture.commits).toEqual({
		{
			events = { { id = "Added", payload = "Buff.Stack" } },
			state = {
				["Status.Burning"] = { stackCount = 1, expiresAt = 1010 },
				["Buff.Stack"] = { stackCount = 1, expiresAt = 1005.125 },
			},
		},
	})
end)

it("recomputes only the touched stacked Tag's authoritative longest finite timing", function()
	TestUtils.add(fixture, "Status.Burning")
	TestUtils.add(fixture, "Buff.Stack", 2)
	TestUtils.observe(fixture)
	TestUtils.step(fixture, 1)
	fixture.clock.now += 0.25
	TestUtils.add(fixture, "Buff.Stack", 8)

	expect(TestUtils.snapshot(fixture)).toEqual({
		["Status.Burning"] = { stackCount = 1, expiresAt = 1010 },
		["Buff.Stack"] = { stackCount = 2, expiresAt = 1009.25 },
	})

	expect(#fixture.commits).toBe(1)
end)

it("does not enumerate all active Tags or query unrelated instances on the one-Tag mutation path", function()
	TestUtils.add(fixture, "Status.Burning")
	TestUtils.add(fixture, "Status.Permanent")
	TestUtils.add(fixture, "Buff.Stack", 2)
	TestUtils.observe(fixture)

	fixture.tags.GetActiveTags = function(): { TagTypes.ActiveTagSnapshot }
		error("OneTagMutationMustNotRebuildAllActiveTags")
	end

	local originalInstances = fixture.tags.GetTagInstances

	fixture.tags.GetTagInstances = function(
		self: TagTypes.InternalTagController,
		tagId: string
	): { TagTypes.TagInstanceSnapshot }
		expect(tagId).toBe("Buff.Stack")

		return originalInstances(self, tagId)
	end

	TestUtils.add(fixture, "Buff.Stack", 6)

	expect(fixture.commits).toEqual({
		{
			events = { { id = "Added", payload = "Buff.Stack" } },
			state = {
				["Status.Burning"] = { stackCount = 1, expiresAt = 1010 },
				["Status.Permanent"] = { stackCount = 1 },
				["Buff.Stack"] = { stackCount = 2, expiresAt = 1006 },
			},
		},
	})
end)

for _, visibility: TagTypes.TagVisibility in { "ClientVisible", "ServerOnly" } do
	it("runs " .. visibility .. " onTick callbacks without generating Ticked events or countdown commits", function()
		TestUtils.destroy(fixture)
		local ticks: number = 0

		fixture = TestUtils.new({
			{ id = "Status.Permanent", visibility = "ClientVisible", duplicateBehavior = "Ignore" },
			{
				id = "Status.Ticking",
				visibility = visibility,
				duplicateBehavior = "Refresh",
				defaultDuration = 5,
				tickInterval = 0.5,
				onTick = function(_actor: ActorTypes.Actor, _deltaTime: number)
					ticks += 1
				end,
			},
		})

		TestUtils.add(fixture, "Status.Ticking")
		TestUtils.observe(fixture)

		for _ = 1, 4 do
			TestUtils.step(fixture, 0.5)
		end

		expect(ticks).toBe(4)
		expect(fixture.commits).toEqual({})
		TestUtils.add(fixture, "Status.Permanent")
		expect(#fixture.commits).toBe(1)
		expect(fixture.commits[1].events).toEqual({ { id = "Added", payload = "Status.Permanent" } })
	end)
end

it("does not share projection entries or detach state between Actors using the same generated domain", function()
	local secondActor: ActorTypes.Actor = ActorEntity.new()
	secondActor.enabled = true

	local secondTags: TagTypes.InternalTagController = TagController.new(secondActor) :: TagTypes.InternalTagController
	assert(secondActor:SetController("TagController", secondTags), "Expected second controller installation")

	local second: TestUtils.Fixture = {
		actor = secondActor,
		tags = secondTags,
		definition = fixture.definition,
		clock = fixture.clock,
		commits = {},
		disconnects = {},
	}

	otherFixture = second
	TestUtils.add(fixture, "Status.Burning")
	TestUtils.add(second, "Buff.Stack", 6)
	local disconnect = TestUtils.observe(fixture)
	TestUtils.observe(second)
	expect(TestUtils.snapshot(fixture)).toEqual({ ["Status.Burning"] = { stackCount = 1, expiresAt = 1010 } })
	expect(TestUtils.snapshot(second)).toEqual({ ["Buff.Stack"] = { stackCount = 1, expiresAt = 1006 } })
	TestUtils.add(fixture, "Status.Permanent")
	expect(#fixture.commits).toBe(1)
	expect(second.commits).toEqual({})
	disconnect()
	TestUtils.add(second, "Status.Permanent")
	expect(#fixture.commits).toBe(1)

	expect(second.commits).toEqual({
		{
			events = { { id = "Added", payload = "Status.Permanent" } },
			state = { ["Buff.Stack"] = { stackCount = 1, expiresAt = 1006 }, ["Status.Permanent"] = { stackCount = 1 } },
		},
	})
end)
