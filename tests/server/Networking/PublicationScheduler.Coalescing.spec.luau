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

local scheduler: ServerNetworkingTypes.PublicationScheduler
local stream: ServerNetworkingTypes.PublicationStreamKey = { recipient = "PlayerA", actor = "ActorX" }
beforeEach(function()
	scheduler = TestUtils.createScheduler()
end)
afterEach(function()
	scheduler:Destroy()
end)

local function enqueue(commit: ServerNetworkingTypes.PublicationFilteredCommit): ()
	local success: boolean, reason: string? = scheduler:Enqueue(stream, commit)
	expect(success).toBe(true)
	expect(reason).toBeNil()
end

it("collapses repeated state-only mutations to one latest absolute value and one byte charge", function()
	for sequence: number = 1, 1000 do
		enqueue(TestUtils.scalar(sequence, "Game.Mana", sequence % 100, nil))
	end
	expect(scheduler:GetStreamStatus(stream)).toEqual({
		needsBaseline = false,
		pendingRecords = 1,
		pendingEvents = 0,
		queuedBytes = 16,
	})
	local drained: ServerNetworkingTypes.PublicationDrainResult = scheduler:DrainBudgeted(1024, 8)
	expect(#drained.records).toBe(1)
	expect(drained.records[1].commit).toEqual(TestUtils.scalar(1000, "Game.Mana", 0, nil))
	expect(drained.encodedBytes).toBe(16)
	expect(scheduler:GetStreamStatus(stream).queuedBytes).toBe(0)
end)

it("merges state before an event into its Actor-wide barrier without leaking later state backward", function()
	enqueue(TestUtils.scalar(1, "Game.Mana", 50, nil))
	enqueue(TestUtils.scalar(2, "Game.Guard", 0, "Broken"))
	enqueue(TestUtils.scalar(3, "Game.Mana", 40, nil))
	local drained: ServerNetworkingTypes.PublicationDrainResult = scheduler:DrainBudgeted(1024, 8)
	expect(#drained.records).toBe(2)
	local first: ServerNetworkingTypes.PublicationFilteredCommit = drained.records[1].commit
	local patches: { [string]: ServerNetworkingTypes.PublicationPatch } = {}
	for _, patch: ServerNetworkingTypes.PublicationDomainPatch in first.patches do
		patches[patch.domainId] = patch.patch
	end
	expect(patches).toEqual({
		["Game.Mana"] = { kind = "Replace", value = 50 },
		["Game.Guard"] = { kind = "Replace", value = 0 },
	})
	expect(first.events).toEqual({ { domainId = "Game.Guard", eventId = "Broken", payload = {} } })
	expect(first.sequence).toBe(2)
	expect(drained.records[2].commit).toEqual(TestUtils.scalar(3, "Game.Mana", 40, nil))
end)

it("preserves Start and End as two ordered barriers even in one drain", function()
	local started: ServerNetworkingTypes.PublicationFilteredCommit = TestUtils.scalar(1, "Game.Action", true, "Started")
	local ended: ServerNetworkingTypes.PublicationFilteredCommit = TestUtils.scalar(2, "Game.Action", false, "Ended")
	enqueue(started)
	enqueue(ended)
	local drained: ServerNetworkingTypes.PublicationDrainResult = scheduler:DrainBudgeted(1024, 8)
	expect(#drained.records).toBe(2)
	expect(drained.records[1].commit).toEqual(started)
	expect(drained.records[2].commit).toEqual(ended)
end)

it("retains separate event-only barriers without manufacturing state patches", function()
	for sequence: number = 1, 2 do
		enqueue({
			sequence = sequence,
			patches = {},
			events = { { domainId = "Game.Action", eventId = "Pulse", payload = { count = sequence } } },
		})
	end
	local drained: ServerNetworkingTypes.PublicationDrainResult = scheduler:DrainBudgeted(1024, 8)
	expect(#drained.records).toBe(2)
	expect(drained.records[1].commit.patches).toEqual({})
	expect(drained.records[1].commit.events[1].payload).toEqual({ count = 1 })
	expect(drained.records[2].commit.events[1].payload).toEqual({ count = 2 })
end)

it("composes repeated and disjoint nested Struct field changes", function()
	enqueue(TestUtils.patch(1, {
		kind = "Struct",
		fields = {
			current = { kind = "Replace", value = 50 },
			nested = { kind = "Struct", fields = { active = { kind = "Replace", value = true } } },
		},
	}))
	enqueue(TestUtils.patch(2, {
		kind = "Struct",
		fields = { current = { kind = "Replace", value = 40 }, maximum = { kind = "Replace", value = 80 } },
	}))
	local drained: ServerNetworkingTypes.PublicationDrainResult = scheduler:DrainBudgeted(1024, 8)
	expect(#drained.records).toBe(1)
	expect(drained.records[1].commit.patches).toEqual({
		{
			domainId = "Game.State",
			patch = {
				kind = "Struct",
				fields = {
					current = { kind = "Replace", value = 40 },
					maximum = { kind = "Replace", value = 80 },
					nested = { kind = "Struct", fields = { active = { kind = "Replace", value = true } } },
				},
			},
		},
	})
end)

it("preserves explicit Optional removal when an earlier tail made it present", function()
	enqueue(TestUtils.patch(1, { kind = "Struct", fields = { target = { kind = "Replace", value = "Enemy" } } }))
	enqueue(TestUtils.patch(2, { kind = "Struct", fields = { target = { kind = "Replace" } } }))
	local drained: ServerNetworkingTypes.PublicationDrainResult = scheduler:DrainBudgeted(1024, 8)
	expect(drained.records[1].commit.patches).toEqual({
		{ domainId = "Game.State", patch = { kind = "Struct", fields = { target = { kind = "Replace" } } } },
	})
end)

it("collapses Map add then update to the final whole-entry value", function()
	enqueue(TestUtils.patch(1, { kind = "Map", entries = { Haste = { stacks = 1, active = true } }, removed = {} }))
	enqueue(TestUtils.patch(2, { kind = "Map", entries = { Haste = { stacks = 2, active = false } }, removed = {} }))
	local drained: ServerNetworkingTypes.PublicationDrainResult = scheduler:DrainBudgeted(1024, 8)
	expect(drained.records[1].commit.patches).toEqual({
		{
			domainId = "Game.State",
			patch = { kind = "Map", entries = { Haste = { stacks = 2, active = false } }, removed = {} },
		},
	})
end)

it("cancels a Map add then remove when the delivered baseline proves the key was absent", function()
	scheduler:ResetAfterBaseline(stream, { ["Game.State"] = { value = {} } })
	enqueue(TestUtils.patch(1, { kind = "Map", entries = { Haste = 1 }, removed = {} }))
	enqueue(TestUtils.patch(2, { kind = "Map", entries = {}, removed = { "Haste" } }))
	expect(scheduler:DrainBudgeted(1024, 8).records).toEqual({})
	expect(scheduler:GetStreamStatus(stream).queuedBytes).toBe(0)
end)

it("keeps Map removal when no delivered baseline established absence", function()
	enqueue(TestUtils.patch(1, { kind = "Map", entries = { Haste = 1 }, removed = {} }))
	enqueue(TestUtils.patch(2, { kind = "Map", entries = {}, removed = { "Haste" } }))
	local drained: ServerNetworkingTypes.PublicationDrainResult = scheduler:DrainBudgeted(1024, 8)
	expect(#drained.records).toBe(1)
	expect(drained.records[1].commit.sequence).toBe(2)
	expect(drained.records[1].commit.patches).toEqual({
		{ domainId = "Game.State", patch = { kind = "Map", entries = {}, removed = { "Haste" } } },
	})
end)

it("advances delivered Map truth after drain so a later update and removal cannot cancel", function()
	scheduler:ResetAfterBaseline(stream, { ["Game.State"] = { value = {} } })
	local added: ServerNetworkingTypes.PublicationFilteredCommit = TestUtils.patch(1, {
		kind = "Map",
		entries = { Haste = 1 },
		removed = {},
	})
	enqueue(added)
	local firstDrain: ServerNetworkingTypes.PublicationDrainResult = scheduler:DrainBudgeted(1024, 8)
	expect(#firstDrain.records).toBe(1)
	expect(firstDrain.records[1].commit).toEqual(added)
	enqueue(TestUtils.patch(2, { kind = "Map", entries = { Haste = 2 }, removed = {} }))
	enqueue(TestUtils.patch(3, { kind = "Map", entries = {}, removed = { "Haste" } }))
	local secondDrain: ServerNetworkingTypes.PublicationDrainResult = scheduler:DrainBudgeted(1024, 8)
	expect(#secondDrain.records).toBe(1)
	expect(secondDrain.records[1].commit.sequence).toBe(3)
	expect(secondDrain.records[1].commit.patches).toEqual({
		{ domainId = "Game.State", patch = { kind = "Map", entries = {}, removed = { "Haste" } } },
	})
end)

it("keeps a Map removal after an undrained event barrier added the key", function()
	scheduler:ResetAfterBaseline(stream, { ["Game.State"] = { value = {} } })
	enqueue({
		sequence = 1,
		patches = { { domainId = "Game.State", patch = { kind = "Map", entries = { Haste = 1 }, removed = {} } } },
		events = { { domainId = "Game.State", eventId = "Applied", payload = {} } },
	})
	enqueue(TestUtils.patch(2, { kind = "Map", entries = { Haste = 2 }, removed = {} }))
	enqueue(TestUtils.patch(3, { kind = "Map", entries = {}, removed = { "Haste" } }))
	local drained: ServerNetworkingTypes.PublicationDrainResult = scheduler:DrainBudgeted(1024, 8)
	expect(#drained.records).toBe(2)
	expect(drained.records[2].commit.patches).toEqual({
		{ domainId = "Game.State", patch = { kind = "Map", entries = {}, removed = { "Haste" } } },
	})
end)

it("keeps Map removal when the baseline key existed instead of cancelling an update then remove", function()
	scheduler:ResetAfterBaseline(stream, { ["Game.State"] = { value = { Haste = 1 } } })
	enqueue(TestUtils.patch(1, { kind = "Map", entries = { Haste = 2 }, removed = {} }))
	enqueue(TestUtils.patch(2, { kind = "Map", entries = {}, removed = { "Haste" } }))
	local drained: ServerNetworkingTypes.PublicationDrainResult = scheduler:DrainBudgeted(1024, 8)
	expect(drained.records[1].commit.patches).toEqual({
		{ domainId = "Game.State", patch = { kind = "Map", entries = {}, removed = { "Haste" } } },
	})
end)

it("collapses Map remove then add to final truth without keeping a contradictory removal", function()
	enqueue(TestUtils.patch(1, { kind = "Map", entries = {}, removed = { "Haste" } }))
	enqueue(TestUtils.patch(2, { kind = "Map", entries = { Haste = 3 }, removed = {} }))
	local drained: ServerNetworkingTypes.PublicationDrainResult = scheduler:DrainBudgeted(1024, 8)
	expect(drained.records[1].commit.patches).toEqual({
		{ domainId = "Game.State", patch = { kind = "Map", entries = { Haste = 3 }, removed = {} } },
	})
end)

it("collapses Array replacements to the newest ordered value", function()
	enqueue(TestUtils.patch(1, { kind = "Replace", value = { 1, 2 } }))
	enqueue(TestUtils.patch(2, { kind = "Replace", value = { 2, 1, 3 } }))
	local drained: ServerNetworkingTypes.PublicationDrainResult = scheduler:DrainBudgeted(1024, 8)
	expect(drained.records[1].commit.patches).toEqual({
		{ domainId = "Game.State", patch = { kind = "Replace", value = { 2, 1, 3 } } },
	})
end)

it("uses recipient and Actor identities rather than the StreamKey table identity", function()
	enqueue(TestUtils.scalar(1, "Game.Mana", 50, nil))
	local sameStream: ServerNetworkingTypes.PublicationStreamKey =
		{ recipient = stream.recipient, actor = stream.actor }
	expect(scheduler:Enqueue(sameStream, TestUtils.scalar(2, "Game.Mana", 40, nil))).toBe(true)
	local drained: ServerNetworkingTypes.PublicationDrainResult = scheduler:DrainBudgeted(1024, 8)
	expect(#drained.records).toBe(1)
	expect(drained.records[1].commit).toEqual(TestUtils.scalar(2, "Game.Mana", 40, nil))
end)

it("shares immutable authoritative data across recipient queues without mutating either input", function()
	local patch: ServerNetworkingTypes.PublicationPatch = { kind = "Replace", value = 50 }
	local commit: ServerNetworkingTypes.PublicationFilteredCommit = {
		sequence = 1,
		patches = { { domainId = "Game.Mana", patch = patch } },
		events = {},
	}
	table.freeze(patch)
	table.freeze(commit.patches[1])
	table.freeze(commit.patches)
	table.freeze(commit.events)
	table.freeze(commit)
	local other: ServerNetworkingTypes.PublicationStreamKey = { recipient = "PlayerB", actor = stream.actor }
	enqueue(commit)
	expect(scheduler:Enqueue(other, commit)).toBe(true)
	enqueue(TestUtils.scalar(2, "Game.Mana", 40, nil))
	local drained: ServerNetworkingTypes.PublicationDrainResult = scheduler:DrainBudgeted(1024, 8)
	local recipientValues: { [string]: any } = {}
	for _, record: ServerNetworkingTypes.PublicationRecord in drained.records do
		recipientValues[record.stream.recipient] = record.commit.patches[1].patch
	end
	expect(recipientValues).toEqual({
		PlayerA = { kind = "Replace", value = 40 },
		PlayerB = { kind = "Replace", value = 50 },
	})
	expect(commit).toEqual(TestUtils.scalar(1, "Game.Mana", 50, nil))
end)
