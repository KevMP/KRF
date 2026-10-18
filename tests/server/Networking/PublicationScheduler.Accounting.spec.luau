--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local ServerNetworkingTypes = require(KRF.server.Networking.types)
local TestUtils = require(script.Parent.Parent.Utils.Networking.PublicationSchedulerTestUtils)

local Scheduler: ServerNetworkingTypes.PublicationSchedulerModule =
	require(KRF.server.Networking.utils.PublicationScheduler)

local scheduler: ServerNetworkingTypes.PublicationScheduler
local stream: ServerNetworkingTypes.PublicationStreamKey = { recipient = "PlayerA", actor = "ActorX" }

beforeEach(function()
	scheduler = TestUtils.createScheduler()
end)

afterEach(function()
	scheduler:Destroy()
end)

it("keeps exact queue charges through tail sealing, partial drain, cancellation and replacement reset", function()
	scheduler:ResetAfterBaseline(stream, { ["Game.State"] = { value = {} } })
	expect(scheduler:Enqueue(stream, TestUtils.scalar(1, "Game.Other", 1, "Changed"))).toBe(true)
	expect(scheduler:Enqueue(stream, TestUtils.scalar(2, "Game.Other", 2, nil))).toBe(true)
	expect(scheduler:Enqueue(stream, TestUtils.scalar(3, "Game.Other", 3, "Changed"))).toBe(true)

	expect(scheduler:GetStreamStatus(stream)).toEqual({
		needsBaseline = false,
		pendingRecords = 2,
		pendingEvents = 2,
		queuedBytes = 32,
	})

	expect(#scheduler:DrainBudgeted(16, 1).records).toBe(1)

	expect(scheduler:GetStreamStatus(stream)).toEqual({
		needsBaseline = false,
		pendingRecords = 1,
		pendingEvents = 1,
		queuedBytes = 16,
	})

	expect(scheduler:Enqueue(stream, TestUtils.patch(4, { kind = "Map", entries = { Added = 1 }, removed = {} }))).toBe(
		true
	)

	expect(scheduler:GetStreamStatus(stream).queuedBytes).toBe(32)

	expect(scheduler:Enqueue(stream, TestUtils.patch(5, { kind = "Map", entries = {}, removed = { "Added" } }))).toBe(
		true
	)

	expect(scheduler:GetStreamStatus(stream)).toEqual({
		needsBaseline = false,
		pendingRecords = 1,
		pendingEvents = 1,
		queuedBytes = 16,
	})

	scheduler:MarkBaselinePending(stream)

	expect(scheduler:GetStreamStatus(stream)).toEqual({
		needsBaseline = true,
		pendingRecords = 0,
		pendingEvents = 0,
		queuedBytes = 0,
	})

	scheduler:ResetAfterBaseline(stream, {})
	expect(scheduler:Enqueue(stream, TestUtils.scalar(6, "Game.Other", 6, "Changed"))).toBe(true)
	expect(scheduler:DrainBudgeted(16, 1).encodedBytes).toBe(16)

	expect(scheduler:GetStreamStatus(stream)).toEqual({
		needsBaseline = false,
		pendingRecords = 0,
		pendingEvents = 0,
		queuedBytes = 0,
	})
end)

it("releases drained barrier capacity before admitting new events at the exact limit", function()
	scheduler:Destroy()

	scheduler = Scheduler.new({
		maxBarriers = 2,
		maxEvents = 2,
		maxQueuedBytes = 32,
		MeasureRecord = function(): number
			return 16
		end,
	})

	for sequence: number = 1, 2 do
		expect(scheduler:Enqueue(stream, TestUtils.scalar(sequence, "Game.State", sequence, "Changed"))).toBe(true)
	end

	expect(#scheduler:DrainBudgeted(16, 1).records).toBe(1)
	expect(scheduler:Enqueue(stream, TestUtils.scalar(3, "Game.State", 3, "Changed"))).toBe(true)

	expect(scheduler:GetStreamStatus(stream)).toEqual({
		needsBaseline = false,
		pendingRecords = 2,
		pendingEvents = 2,
		queuedBytes = 32,
	})

	local success: boolean, reason: string? = scheduler:Enqueue(stream, TestUtils.scalar(4, "Game.State", 4, "Changed"))
	expect(success).toBe(false)
	expect(reason).toBe("PublicationStreamOverloaded")
	scheduler:ResetAfterBaseline(stream, {})
	expect(scheduler:Enqueue(stream, TestUtils.scalar(5, "Game.State", 5, "Changed"))).toBe(true)

	expect(scheduler:GetStreamStatus(stream)).toEqual({
		needsBaseline = false,
		pendingRecords = 1,
		pendingEvents = 1,
		queuedBytes = 16,
	})
end)

it("keeps nested baseline ownership and map-removal truth across undrained barriers", function()
	local baseline: any = { nested = { Existing = { count = 1 } } }
	scheduler:ResetAfterBaseline(stream, { ["Game.State"] = { value = baseline } })
	baseline.nested.Existing = nil

	local addedPatch: ServerNetworkingTypes.PublicationPatch = {
		kind = "Struct",
		fields = { nested = { kind = "Map", entries = { Added = { count = 2 } }, removed = {} } },
	}

	local barrier: ServerNetworkingTypes.PublicationFilteredCommit = {
		sequence = 1,
		patches = { { domainId = "Game.State", patch = addedPatch } },
		events = { { domainId = "Game.State", eventId = "Added", payload = {} } },
	}

	local updated: ServerNetworkingTypes.PublicationPatch = {
		kind = "Struct",
		fields = {
			nested = { kind = "Map", entries = { Existing = { count = 3 }, Added = { count = 4 } }, removed = {} },
		},
	}

	local removed: ServerNetworkingTypes.PublicationPatch = {
		kind = "Struct",
		fields = { nested = { kind = "Map", entries = {}, removed = { "Added", "Existing" } } },
	}

	expect(scheduler:Enqueue(stream, barrier)).toBe(true)
	expect(scheduler:Enqueue(stream, TestUtils.patch(2, updated))).toBe(true)
	expect(scheduler:Enqueue(stream, TestUtils.patch(3, removed))).toBe(true)

	local drained: ServerNetworkingTypes.PublicationDrainResult = scheduler:DrainBudgeted(1024, 8)
	expect(#drained.records).toBe(2)

	expect(drained.records[2].commit.patches).toEqual({
		{
			domainId = "Game.State",
			patch = {
				kind = "Struct",
				fields = {
					nested = { kind = "Map", entries = {}, removed = { "Added", "Existing" } },
				},
			},
		},
	})

	expect(barrier.patches[1].patch).toEqual({
		kind = "Struct",
		fields = {
			nested = { kind = "Map", entries = { Added = { count = 2 } }, removed = {} },
		},
	})

	expect(baseline).toEqual({ nested = {} })
end)
