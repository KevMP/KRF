--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local TagTypes = require(ReplicatedStorage.Packages.KRF.server.Tags.types)
local TestUtils = require(script.Parent.Parent.Utils.Networking.TagsReplicationTestUtils)

local fixture: TestUtils.Fixture

beforeEach(function()
	fixture = TestUtils.new()
end)

afterEach(function()
	TestUtils.destroy(fixture)
end)

it("installs every touched entry before one batch callback and preserves visible relative event order", function()
	TestUtils.observe(fixture)
	fixture.tags:_beginMutationBatch()
	TestUtils.add(fixture, "Status.Burning")
	TestUtils.add(fixture, "Private.Refresh")
	TestUtils.add(fixture, "Status.Permanent")
	TestUtils.add(fixture, "Status.Burning", 12)
	expect(fixture.tags:RemoveTag("Private.Refresh")).toBe(true)
	TestUtils.add(fixture, "Buff.Stack", 4)
	expect(fixture.commits).toEqual({})
	local events: { TagTypes.TagMutationEvent } = fixture.tags:_finishMutationBatch()

	expect(fixture.commits).toEqual({
		{
			events = {
				{ id = "Added", payload = "Status.Burning" },
				{ id = "Added", payload = "Status.Permanent" },
				{ id = "Refreshed", payload = "Status.Burning" },
				{ id = "Added", payload = "Buff.Stack" },
			},
			state = {
				["Status.Burning"] = { stackCount = 1, expiresAt = 1012 },
				["Status.Permanent"] = { stackCount = 1 },
				["Buff.Stack"] = { stackCount = 1, expiresAt = 1004 },
			},
		},
	})

	fixture.tags:_dispatchMutationEvents(events)
	expect(#fixture.commits).toBe(1)
end)

it("preserves Add then Remove occurrences even when the batch ends with empty state", function()
	TestUtils.observe(fixture)
	fixture.tags:_beginMutationBatch()
	TestUtils.add(fixture, "Status.Permanent")
	expect(fixture.tags:RemoveTag("Status.Permanent")).toBe(true)
	local events: { TagTypes.TagMutationEvent } = fixture.tags:_finishMutationBatch()

	expect(fixture.commits).toEqual({
		{
			events = {
				{ id = "Added", payload = "Status.Permanent" },
				{ id = "Removed", payload = "Status.Permanent" },
			},
			state = {},
		},
	})

	fixture.tags:_dispatchMutationEvents(events)
end)

it("defers nested batches until the outer Commit and does not publish again during Dispatch", function()
	TestUtils.observe(fixture)
	fixture.tags:_beginMutationBatch()
	TestUtils.add(fixture, "Status.Permanent")
	fixture.tags:_beginMutationBatch()
	TestUtils.add(fixture, "Status.Burning")
	expect(fixture.tags:_finishMutationBatch()).toEqual({})
	expect(fixture.commits).toEqual({})
	local events: { TagTypes.TagMutationEvent } = fixture.tags:_finishMutationBatch()
	expect(#fixture.commits).toBe(1)

	expect(fixture.commits[1].events).toEqual({
		{ id = "Added", payload = "Status.Permanent" },
		{ id = "Added", payload = "Status.Burning" },
	})

	fixture.tags:_dispatchMutationEvents(events)
	expect(#fixture.commits).toBe(1)
end)

it("ignores empty and all-private batches without suppressing the following visible batch", function()
	TestUtils.observe(fixture)
	fixture.tags:_beginMutationBatch()
	fixture.tags:_dispatchMutationEvents(fixture.tags:_finishMutationBatch())
	fixture.tags:_beginMutationBatch()
	TestUtils.add(fixture, "Private.Refresh")
	TestUtils.add(fixture, "Private.Refresh")
	expect(fixture.tags:RemoveTag("Private.Refresh")).toBe(true)
	fixture.tags:_dispatchMutationEvents(fixture.tags:_finishMutationBatch())
	expect(fixture.commits).toEqual({})
	fixture.tags:_beginMutationBatch()
	TestUtils.add(fixture, "Status.Permanent")
	fixture.tags:_dispatchMutationEvents(fixture.tags:_finishMutationBatch())

	expect(fixture.commits).toEqual({
		{
			events = { { id = "Added", payload = "Status.Permanent" } },
			state = { ["Status.Permanent"] = { stackCount = 1 } },
		},
	})
end)
