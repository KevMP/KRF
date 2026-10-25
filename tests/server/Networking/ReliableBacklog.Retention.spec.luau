--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local Types = require(KRF.server.Networking.types)
local Backlog = require(KRF.server.Networking.utils.ReliableBacklog)
local Scheduler = require(KRF.server.Networking.utils.PublicationScheduler)
local Commits = require(script.Parent.Parent.Utils.Networking.PublicationSchedulerTestUtils)
local Awareness = require(script.Parent.Parent.Utils.Networking.AwarenessTestUtils)
local pool: Types.ReliableBacklog
local scheduler: Types.PublicationScheduler
local fixture: Awareness.Fixture?

beforeEach(function()
	pool = Backlog.new({
		maxRecords = 16,
		maxBytes = 96,
		actorRecords = 16,
		actorBytes = 96,
		recipientRecords = 16,
		recipientBytes = 96,
		recoveryRecords = 0,
		recoveryBytes = 0,
	}, 0)

	scheduler = Scheduler.new({
		backlog = pool,
		maxBarriers = 8,
		maxEvents = 16,
		maxQueuedBytes = 256,
		MeasureRecord = function(commit: Types.PublicationFilteredCommit): number
			local patch = commit.patches[1].patch

			return if patch.kind == "Replace" then patch.value else 16
		end,
	})
end)

afterEach(function()
	scheduler:Destroy()
	pool:Destroy()

	if fixture ~= nil then
		Awareness.destroy(fixture)
		fixture = nil
	end
end)

it("charges shared immutable payload once and replaces only the coalesced tail's ownership", function()
	local first: Types.PublicationStreamKey = { recipient = "First", actor = "Actor" }
	local second: Types.PublicationStreamKey = { recipient = "Second", actor = "Actor" }
	local shared = Commits.scalar(1, "Game.State", 16, nil)
	expect(scheduler:Enqueue(first, shared)).toBe(true)
	expect(scheduler:Enqueue(second, shared)).toBe(true)
	expect((pool :: any).records).toBe(2)
	expect((pool :: any).bytes).toBe(16)
	expect(scheduler:Enqueue(first, Commits.scalar(2, "Game.State", 24, nil))).toBe(true)
	expect((pool :: any).records).toBe(2)
	expect((pool :: any).bytes).toBe(40)
	scheduler:RemoveStream(first)
	scheduler:RemoveStream(first)
	expect((pool :: any).bytes).toBe(16)
	scheduler:ResetAfterBaseline(second, {})
	expect((pool :: any).records).toBe(0)
	expect((pool :: any).bytes).toBe(0)
end)

it("releases all ownership when a delivered-truth Map tail cancels to nothing", function()
	local key: Types.PublicationStreamKey = { recipient = "First", actor = "Actor" }
	scheduler:ResetAfterBaseline(key, { ["Game.State"] = { value = {} } })
	expect(scheduler:Enqueue(key, Commits.patch(1, { kind = "Map", entries = { Added = 1 }, removed = {} }))).toBe(true)
	expect((pool :: any).bytes).toBe(16)
	expect(scheduler:Enqueue(key, Commits.patch(2, { kind = "Map", entries = {}, removed = { "Added" } }))).toBe(true)
	expect(scheduler:GetStreamStatus(key).needsBaseline).toBe(false)
	expect((pool :: any).records).toBe(0)
	expect((pool :: any).bytes).toBe(0)
end)

it("refuses excess aggregate bytes without evicting other streams and reuses consumed capacity", function()
	for index = 1, 4 do
		local key: Types.PublicationStreamKey = { recipient = index, actor = index }
		expect(scheduler:Enqueue(key, Commits.scalar(index, "Game.State", 24, "Changed"))).toBe(true)
	end

	expect((pool :: any).bytes).toBe(96)
	local refused: Types.PublicationStreamKey = { recipient = 5, actor = 5 }
	local admitted, reason = scheduler:Enqueue(refused, Commits.scalar(5, "Game.State", 24, "Changed"))
	expect(admitted).toBe(false)
	expect(reason).toBe("PublicationAggregateOverloaded")
	expect(scheduler:GetStreamStatus(refused).needsBaseline).toBe(true)
	expect((pool :: any).records).toBe(4)
	expect(#scheduler:DrainBudgeted(24, 1).records).toBe(1)
	expect((pool :: any).bytes).toBe(72)
	scheduler:ResetAfterBaseline(refused, {})
	expect(scheduler:Enqueue(refused, Commits.scalar(6, "Game.State", 24, "Changed"))).toBe(true)
	expect((pool :: any).bytes).toBe(96)
end)

it("keeps staged ownership across disconnect and does not release a reconnected owner's charges", function()
	local key: Types.PublicationStreamKey = { recipient = "First", actor = "Actor" }
	local old = assert(pool:Acquire(key, {}, 16, nil, true))
	old.stage()
	pool:CloseRecipient(key.recipient)
	expect((pool :: any).records).toBe(1)
	local fresh = assert(pool:Acquire(key, {}, 16, nil, true))
	old.resume()
	old.release()
	expect((pool :: any).records).toBe(1)
	expect((pool :: any).bytes).toBe(16)
	pool:Destroy()
	fresh.resume()
	fresh.release()
	expect((pool :: any).bytes).toBe(0)
	expect(pool:Acquire(key, {}, 16, nil, true)).toBeNil()
end)

it("does not retain an unadmitted oversized baseline in the reusable projection cache", function()
	local created = Awareness.new()
	fixture = created
	created.options.maxBaselineBytes = 1

	local actor = Awareness.actor(created, nil)
	local runtime = Awareness.start(created)
	Awareness.ready(created, Awareness.player(created))
	-- Actual recipient size is checked during the budgeted projection turn.
	runtime:Step(32768, 128)
	expect(created.faults[1].reason).toBe("ActorBaselineTooLarge")
	expect((runtime :: any).backlog.records).toBe(0)
	expect((runtime :: any).projections.baselines[actor] == nil).toBe(true)
end)

it("keeps a non-growing state tail coalescible when baselines occupy reserved capacity", function()
	local internal: any = pool
	internal.limits.recoveryRecords = 15
	internal.limits.recoveryBytes = 32

	local key: Types.PublicationStreamKey = { recipient = "First", actor = "Actor" }
	expect(scheduler:Enqueue(key, Commits.scalar(1, "Game.State", 16, nil))).toBe(true)
	local baseline = assert(pool:Acquire({ recipient = "Other", actor = "Other" }, {}, 64, nil, true))
	expect(internal.bytes).toBe(80)
	local coalesced, reason = scheduler:Enqueue(key, Commits.scalar(2, "Game.State", 8, nil))
	expect(coalesced).toBe(true)
	expect(reason).toBeNil()
	expect(scheduler:GetStreamStatus(key).needsBaseline).toBe(false)
	expect(internal.records).toBe(2)
	expect(internal.bytes).toBe(72)
	baseline.release()
	scheduler:DrainBudgeted(96, 1)
	expect(internal.records).toBe(0)
	expect(internal.bytes).toBe(0)
end)
