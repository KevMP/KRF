--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF

local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local PublicationTypes = require(KRF.server.Networking.PublicationTypes)
local SchemaTypes = require(KRF.shared.Networking.types)
local Schema: SchemaTypes.Schema = require(KRF.shared.Networking.Schema)
local SchemaCompiler: SchemaTypes.SchemaCompiler = require(KRF.shared.Networking.utils.SchemaCompiler)
local Codecs: SchemaTypes.CodecCompiler = require(KRF.shared.Networking.CodecCompiler)
local Scheduler: PublicationTypes.SchedulerModule = require(KRF.server.Networking.PublicationScheduler)
local TestUtils = require(script.Parent.Parent.Utils.Networking.PublicationSchedulerTestUtils)

local scheduler: PublicationTypes.Scheduler
local stream: PublicationTypes.StreamKey = { recipient = "PlayerA", actor = "ActorX" }
beforeEach(function()
	scheduler = TestUtils.createScheduler()
end)
afterEach(function()
	scheduler:Destroy()
end)

it("does no stream traversal or record sizing while idle even with dozens of dormant streams", function()
	local measureCalls: number = 0
	scheduler:Destroy()
	scheduler = Scheduler.new({
		maxBarriers = 8,
		maxEvents = 16,
		maxQueuedBytes = 1024,
		MeasureRecord = function(): number
			measureCalls += 1
			return 16
		end,
	})
	for actorIndex: number = 1, 64 do
		for recipientIndex: number = 1, 8 do
			scheduler:ResetAfterBaseline({ recipient = recipientIndex, actor = actorIndex }, {})
		end
	end
	for _ = 1, 10 do
		local drained: PublicationTypes.DrainResult = scheduler:DrainBudgeted(64, 4)
		expect(drained).toEqual({ records = {}, encodedBytes = 0, visitedStreams = 0 })
	end
	expect(measureCalls).toBe(0)
end)

it("activates only the enqueued stream and returns to idle after it drains", function()
	for actorIndex: number = 1, 64 do
		scheduler:ResetAfterBaseline({ recipient = stream.recipient, actor = actorIndex }, {})
	end
	expect(scheduler:Enqueue(stream, TestUtils.scalar(1, "Game.State", 1, nil))).toBe(true)
	local drained: PublicationTypes.DrainResult = scheduler:DrainBudgeted(16, 1)
	expect(#drained.records).toBe(1)
	expect(drained.visitedStreams).toBe(1)
	expect(drained.records[1].stream).toEqual(stream)
	expect(scheduler:DrainBudgeted(16, 1)).toEqual({ records = {}, encodedBytes = 0, visitedStreams = 0 })
end)

it("does not duplicate active entries when a stream is repeatedly reactivated", function()
	for sequence: number = 1, 20 do
		expect(scheduler:Enqueue(stream, TestUtils.scalar(sequence, "Game.State", sequence, nil))).toBe(true)
		local drained: PublicationTypes.DrainResult = scheduler:DrainBudgeted(64, 4)
		expect(#drained.records).toBe(1)
		expect(drained.visitedStreams).toBe(1)
		expect(scheduler:DrainBudgeted(64, 4).visitedStreams).toBe(0)
	end
end)

for _, limits: { number } in { { 32, 8, 2 }, { 128, 1, 1 }, { 15, 8, 0 }, { 0, 8, 0 }, { 128, 0, 0 } } do
	it(
		"respects a "
			.. limits[1]
			.. "-byte and "
			.. limits[2]
			.. "-record drain budget without discarding unselected work",
		function()
			for sequence: number = 1, 3 do
				expect(scheduler:Enqueue(stream, TestUtils.scalar(sequence, "Game.State", sequence, "Changed"))).toBe(
					true
				)
			end
			local drained: PublicationTypes.DrainResult = scheduler:DrainBudgeted(limits[1], limits[2])
			expect(#drained.records).toBe(limits[3])
			expect(drained.encodedBytes).toBe(limits[3] * 16)
			expect(drained.encodedBytes <= limits[1]).toBe(true)
			expect(scheduler:GetStreamStatus(stream).pendingRecords).toBe(3 - limits[3])
			local remaining: PublicationTypes.DrainResult = scheduler:DrainBudgeted(128, 8)
			expect(#remaining.records).toBe(3 - limits[3])
		end
	)
end

for _, sameRecipient: boolean in { true, false } do
	it(
		"prevents a continuously busy stream from starving another " .. (if sameRecipient then "Actor" else "recipient"),
		function()
			local quiet: PublicationTypes.StreamKey = {
				recipient = if sameRecipient then stream.recipient else "PlayerB",
				actor = if sameRecipient then "ActorY" else stream.actor,
			}
			expect(scheduler:Enqueue(stream, TestUtils.scalar(1, "Game.State", 1, "Changed"))).toBe(true)
			expect(scheduler:Enqueue(quiet, TestUtils.scalar(1, "Game.State", 1, "Changed"))).toBe(true)
			local quietDelivered: boolean = false
			for sequence: number = 2, 3 do
				expect(scheduler:Enqueue(stream, TestUtils.scalar(sequence, "Game.State", sequence, "Changed"))).toBe(
					true
				)
				local drained: PublicationTypes.DrainResult = scheduler:DrainBudgeted(16, 1)
				expect(#drained.records).toBe(1)
				if
					drained.records[1].stream.recipient == quiet.recipient
					and drained.records[1].stream.actor == quiet.actor
				then
					quietDelivered = true
				end
			end
			expect(quietDelivered).toBe(true)
		end
	)
end

type OverflowCase = { name: string, barriers: number, events: number, bytes: number }
local overflowCases: { OverflowCase } = {
	{ name = "sealed barrier count", barriers = 2, events = 100, bytes = 1024 },
	{ name = "semantic event count", barriers = 100, events = 2, bytes = 1024 },
	{ name = "encoded queue bytes", barriers = 100, events = 100, bytes = 32 },
}
for _, case: OverflowCase in overflowCases do
	it("admits the exact " .. case.name .. " limit then becomes discontinuous on the next record", function()
		scheduler:Destroy()
		scheduler = Scheduler.new({
			maxBarriers = case.barriers,
			maxEvents = case.events,
			maxQueuedBytes = case.bytes,
			MeasureRecord = function(): number
				return 16
			end,
		})
		for sequence: number = 1, 2 do
			local success: boolean, reason: string? =
				scheduler:Enqueue(stream, TestUtils.scalar(sequence, "Game.State", sequence, "Changed"))
			expect(success).toBe(true)
			expect(reason).toBeNil()
		end
		expect(scheduler:GetStreamStatus(stream)).toEqual({
			needsBaseline = false,
			pendingRecords = 2,
			pendingEvents = 2,
			queuedBytes = 32,
		})
		local success: boolean, reason: string? =
			scheduler:Enqueue(stream, TestUtils.scalar(3, "Game.State", 3, "Changed"))
		expect(success).toBe(false)
		expect(reason).toBe("PublicationStreamOverloaded")
		expect(scheduler:GetStreamStatus(stream)).toEqual({
			needsBaseline = true,
			pendingRecords = 0,
			pendingEvents = 0,
			queuedBytes = 0,
		})
		expect(scheduler:DrainBudgeted(1024, 8).records).toEqual({})
	end)
end

it("counts multiple semantic events inside one barrier against the event bound", function()
	scheduler:Destroy()
	scheduler = Scheduler.new({
		maxBarriers = 8,
		maxEvents = 1,
		maxQueuedBytes = 1024,
		MeasureRecord = function(): number
			return 16
		end,
	})
	local success: boolean, reason: string? = scheduler:Enqueue(stream, {
		sequence = 1,
		patches = {},
		events = {
			{ domainId = "Game.State", eventId = "First", payload = {} },
			{ domainId = "Game.State", eventId = "Second", payload = {} },
		},
	})
	expect(success).toBe(false)
	expect(reason).toBe("PublicationStreamOverloaded")
	expect(scheduler:GetStreamStatus(stream).needsBaseline).toBe(true)
end)

it("rejects a single impossible-sized record instead of leaving undeliverable backlog", function()
	scheduler:Destroy()
	scheduler = Scheduler.new({
		maxBarriers = 8,
		maxEvents = 16,
		maxQueuedBytes = 15,
		MeasureRecord = function(): number
			return 16
		end,
	})
	local success: boolean, reason: string? = scheduler:Enqueue(stream, TestUtils.scalar(1, "Game.State", 1, "Changed"))
	expect(success).toBe(false)
	expect(reason).toBe("PublicationStreamOverloaded")
	expect(scheduler:GetStreamStatus(stream)).toEqual({
		needsBaseline = true,
		pendingRecords = 0,
		pendingEvents = 0,
		queuedBytes = 0,
	})
end)

it("stops retaining both incremental state and event history while a baseline is pending", function()
	scheduler:MarkBaselinePending(stream)
	for sequence: number = 1, 1000 do
		for _, eventId: string in { "", "Changed" } do
			local success: boolean, reason: string? = scheduler:Enqueue(
				stream,
				TestUtils.scalar(sequence, "Game.State", sequence % 100, if eventId == "" then nil else eventId)
			)
			expect(success).toBe(false)
			expect(reason).toBe("PublicationBaselinePending")
		end
	end
	expect(scheduler:GetStreamStatus(stream)).toEqual({
		needsBaseline = true,
		pendingRecords = 0,
		pendingEvents = 0,
		queuedBytes = 0,
	})
	expect(scheduler:DrainBudgeted(1024, 8).records).toEqual({})
end)

it("isolates one discontinuous recipient/Actor stream from the other Actor and other recipient", function()
	local otherActor: PublicationTypes.StreamKey = { recipient = stream.recipient, actor = "ActorY" }
	local otherRecipient: PublicationTypes.StreamKey = { recipient = "PlayerB", actor = stream.actor }
	for _, key: PublicationTypes.StreamKey in { stream, otherActor, otherRecipient } do
		expect(scheduler:Enqueue(key, TestUtils.scalar(1, "Game.State", 1, "Changed"))).toBe(true)
	end
	scheduler:MarkBaselinePending(stream)
	local drained: PublicationTypes.DrainResult = scheduler:DrainBudgeted(1024, 8)
	expect(#drained.records).toBe(2)
	for _, record: PublicationTypes.Record in drained.records do
		expect(record.stream.recipient == stream.recipient and record.stream.actor == stream.actor).toBe(false)
	end
	expect(scheduler:GetStreamStatus(otherActor).needsBaseline).toBe(false)
	expect(scheduler:GetStreamStatus(otherRecipient).needsBaseline).toBe(false)
end)

it("resumes only fresh incremental work after replacement baseline completion", function()
	expect(scheduler:Enqueue(stream, TestUtils.scalar(1, "Game.State", 1, "Changed"))).toBe(true)
	scheduler:MarkBaselinePending(stream)
	scheduler:ResetAfterBaseline(stream, { ["Game.State"] = { value = 5 } })
	local success: boolean, reason: string? = scheduler:Enqueue(stream, TestUtils.scalar(6, "Game.State", 6, "Changed"))
	expect(success).toBe(true)
	expect(reason).toBeNil()
	local drained: PublicationTypes.DrainResult = scheduler:DrainBudgeted(1024, 8)
	expect(#drained.records).toBe(1)
	expect(drained.records[1].commit.sequence).toBe(6)
	expect(scheduler:GetStreamStatus(stream).needsBaseline).toBe(false)
end)

it("removes obsolete stream work idempotently without disturbing other active streams", function()
	local other: PublicationTypes.StreamKey = { recipient = stream.recipient, actor = "ActorY" }
	for _, key: PublicationTypes.StreamKey in { stream, other } do
		expect(scheduler:Enqueue(key, TestUtils.scalar(1, "Game.State", 1, "Changed"))).toBe(true)
	end
	scheduler:RemoveStream(stream)
	scheduler:RemoveStream(stream)
	local drained: PublicationTypes.DrainResult = scheduler:DrainBudgeted(1024, 8)
	expect(#drained.records).toBe(1)
	expect(drained.records[1].stream).toEqual(other)
	expect(scheduler:GetStreamStatus(stream).queuedBytes).toBe(0)
end)

it("bounds representative state churn by live streams rather than mutation count", function()
	for sequence: number = 1, 100 do
		for actorIndex: number = 1, 64 do
			local key: PublicationTypes.StreamKey = { recipient = stream.recipient, actor = actorIndex }
			expect(scheduler:Enqueue(key, TestUtils.scalar(sequence, "Game.State", sequence, nil))).toBe(true)
		end
	end
	local totalBytes: number = 0
	for actorIndex: number = 1, 64 do
		local status: PublicationTypes.StreamStatus =
			scheduler:GetStreamStatus({ recipient = stream.recipient, actor = actorIndex })
		expect(status.pendingRecords).toBe(1)
		expect(status.needsBaseline).toBe(false)
		totalBytes += status.queuedBytes
	end
	expect(totalBytes).toBe(64 * 16)
	local drained: PublicationTypes.DrainResult = scheduler:DrainBudgeted(1024, 64)
	expect(#drained.records).toBe(64)
	expect(drained.encodedBytes).toBe(1024)
end)

it("replaces the mutable tail byte charge using measured N2 bytes for variable-size values", function()
	local compiled: SchemaTypes.CompiledSchema?, compileReason: string? = SchemaCompiler.Compile(Schema.String(32))
	expect(compileReason).toBeNil()
	assert(compiled ~= nil, "Expected String schema")
	local codec: SchemaTypes.CompiledCodec?, codecReason: string? = Codecs.Compile(compiled)
	expect(codecReason).toBeNil()
	assert(codec ~= nil, "Expected String codec")
	local function measure(commit: PublicationTypes.FilteredCommit): number
		local patch: PublicationTypes.Patch = commit.patches[1].patch
		assert(patch.kind == "Replace", "Expected scalar String replacement")
		local bytes: number?, reason: string? = codec.Measure(patch.value)
		assert(bytes ~= nil and reason == nil, "Expected valid encoded String")
		return bytes + 8 -- Synthetic fixed framing, private to this test.
	end
	scheduler:Destroy()
	scheduler = Scheduler.new({ maxBarriers = 8, maxEvents = 16, maxQueuedBytes = 128, MeasureRecord = measure })
	local longer: PublicationTypes.FilteredCommit = TestUtils.scalar(1, "Game.State", "1234567890", nil)
	local shorter: PublicationTypes.FilteredCommit = TestUtils.scalar(2, "Game.State", "KRF", nil)
	expect(scheduler:Enqueue(stream, longer)).toBe(true)
	expect(scheduler:GetStreamStatus(stream).queuedBytes).toBe(measure(longer))
	expect(scheduler:Enqueue(stream, shorter)).toBe(true)
	expect(scheduler:GetStreamStatus(stream).queuedBytes).toBe(measure(shorter))
	expect(scheduler:DrainBudgeted(measure(shorter), 1).encodedBytes).toBe(measure(shorter))
end)
