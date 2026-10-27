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
local pool: Types.ReliableBacklog
local key: Types.PublicationStreamKey = { recipient = "First", actor = "Actor" }

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
end)

afterEach(function()
	pool:Destroy()
end)

it("reuses queued state charge identity and closures through the scheduler but seals semantic barriers", function()
	local scheduler = Scheduler.new({
		backlog = pool,
		retainDrained = true,
		maxBarriers = 8,
		maxEvents = 8,
		maxQueuedBytes = 96,
		MeasureRecord = function(): number
			return 16
		end,
	})

	expect(scheduler:Enqueue(key, Commits.scalar(1, "Game.State", 1, nil))).toBe(true)
	local charge: any = next((pool :: any).recipients[key.recipient].pending)
	local release, stage, resume = charge.release, charge.stage, charge.resume
	local owner, actor = charge.owner, charge.actor
	expect(scheduler:Enqueue(key, Commits.scalar(2, "Game.State", 2, nil))).toBe(true)
	local current = next((pool :: any).recipients[key.recipient].pending)
	expect(current).toBe(charge)
	expect(charge.release).toBe(release)
	expect(charge.stage).toBe(stage)
	expect(charge.resume).toBe(resume)
	expect(charge.owner).toBe(owner)
	expect(charge.actor).toBe(actor)
	expect(charge.payload.sequence).toBe(2)
	expect(scheduler:Enqueue(key, Commits.scalar(3, "Game.State", 3, "Changed"))).toBe(true)
	local drained = scheduler:DrainBudgeted(96, 1).records[1]
	expect(drained.charge == charge).toBe(false)
	expect(drained.commit.sequence).toBe(3)
	expect(drained.commit.events[1].eventId).toBe("Changed")
	assert(drained.charge, "Expected retained semantic barrier ownership").release()
	scheduler:Destroy()
	expect((pool :: any).records).toBe(0)
end)

it("keeps shared payload references and final-use callbacks exact while replacing one owner's queued state", function()
	local shared, replacement = {}, {}
	local oldUnused, newUnused = 0, 0
	local other: Types.PublicationStreamKey = { recipient = "Second", actor = key.actor }

	local first = assert(pool:Acquire(key, shared, 16, nil, nil, function()
		oldUnused += 1
	end, true))

	local second = assert(pool:Acquire(other, shared, 16, nil, nil, nil, true))

	expect(pool:Acquire(key, replacement, 24, first, nil, function()
		newUnused += 1
	end, true)).toBe(first)

	local internal: any = pool
	expect(internal.bytes).toBe(40)
	expect(internal.payloads[shared].references).toBe(1)
	expect(internal.payloads[replacement].references).toBe(1)
	expect(internal.recipients[key.recipient].bytes).toBe(24)
	expect(internal.actors[key.actor].bytes).toBe(40)
	expect(oldUnused).toBe(0)
	second.release()
	second.release()
	expect(oldUnused).toBe(1)
	expect(internal.bytes).toBe(24)
	first.release()
	first.resume()
	first.release()
	expect(newUnused).toBe(1)
	expect(internal.records).toBe(0)
	expect(internal.bytes).toBe(0)
	expect(next(internal.actors)).toBeNil()
	expect(next(internal.recipients)).toBeNil()
end)

it("reuses a queued charge at exact capacity and adjusts both local accounts on growth and shrink", function()
	local internal: any = pool
	internal.limits.maxRecords = 1
	internal.limits.maxBytes = 24

	local first = assert(pool:Acquire(key, {}, 16, nil, nil, nil, true))
	expect(pool:Acquire(key, {}, 24, first, nil, nil, true)).toBe(first)
	expect(internal.bytes).toBe(24)
	expect(internal.records).toBe(1)
	expect(internal.recipients[key.recipient].records).toBe(1)
	expect(internal.actors[key.actor].bytes).toBe(24)
	expect(pool:Acquire(key, {}, 8, first, nil, nil, true)).toBe(first)
	expect(internal.bytes).toBe(8)
	expect(internal.recipients[key.recipient].bytes).toBe(8)
	expect(internal.actors[key.actor].bytes).toBe(8)
	first.release()
	expect(internal.bytes).toBe(0)
end)

it("reuses an already retained payload without double charging it or confusing local delivery bytes", function()
	local shared = {}
	local other: Types.PublicationStreamKey = { recipient = "Second", actor = key.actor }
	local first = assert(pool:Acquire(key, {}, 16, nil, nil, nil, true))
	local second = assert(pool:Acquire(other, shared, 24, nil, nil, nil, true))

	local internal: any = pool
	internal.limits.maxBytes = 24
	expect(pool:Acquire(key, shared, 24, first, nil, nil, true)).toBe(first)
	expect(internal.bytes).toBe(24)
	expect(internal.payloads[shared].references).toBe(2)
	expect(internal.recipients[key.recipient].bytes).toBe(24)
	expect(internal.actors[key.actor].bytes).toBe(48)
	expect(pool:Acquire(key, {}, 32, first, nil, nil, true)).toBeNil()
	expect(internal.payloads[shared].references).toBe(2)
	first.release()
	expect(internal.bytes).toBe(24)
	second.release()
	expect(internal.bytes).toBe(0)
end)

for _, bound: string in { "maxBytes", "actorBytes", "recipientBytes" } do
	it("leaves the original charge and indexes unchanged when " .. bound .. " refuses replacement", function()
		local payload = {}
		local charge = assert(pool:Acquire(key, payload, 16, nil, nil, nil, true))

		local internal: any = pool
		internal.limits[bound] = 24
		expect(pool:Acquire(key, {}, 32, charge, nil, nil, true)).toBeNil()
		expect((charge :: any).payload).toBe(payload)
		expect((charge :: any).bytes).toBe(16)
		expect(internal.bytes).toBe(16)
		expect(internal.records).toBe(1)
		expect(internal.payloads[payload].references).toBe(1)
		expect(internal.recipients[key.recipient].pending[charge]).toBe(true)
		expect(internal.recipients[key.recipient].bytes).toBe(16)
		expect(internal.actors[key.actor].bytes).toBe(16)
	end)
end

it("does not reuse staged ownership or debit a re-Ready session when its old lease unwinds", function()
	local oldUnused = 0

	local old = assert(pool:Acquire(key, {}, 16, nil, nil, function()
		oldUnused += 1
	end, true))

	old.stage()
	local queued = assert(pool:Acquire(key, {}, 24, old, nil, nil, true))
	expect(queued == old).toBe(false)
	expect((old :: any).active).toBe(true)
	expect((old :: any).bytes).toBe(16)
	expect((pool :: any).records).toBe(2)
	pool:CloseRecipient(key.recipient)
	expect((pool :: any).bytes).toBe(16)
	local fresh = assert(pool:Acquire(key, {}, 8, nil, nil, nil, true))
	old.resume()
	old.release()
	queued.release()
	expect(oldUnused).toBe(1)
	expect((pool :: any).records).toBe(1)
	expect((pool :: any).bytes).toBe(8)
	fresh.release()
	expect((pool :: any).bytes).toBe(0)
end)

it("keeps baseline and final-use callback replacements on the original allocation path", function()
	local unused = 0

	local old = assert(pool:Acquire(key, {}, 16, nil, nil, function()
		unused += 1
	end, true))

	local replacement = assert(pool:Acquire(key, {}, 8, old, nil, nil, true))
	expect(replacement == old).toBe(false)
	expect(unused).toBe(1)
	local baseline = assert(pool:Acquire(key, {}, 16, replacement, true, nil, true))
	expect(baseline == replacement).toBe(false)
	baseline.release()
	expect((pool :: any).records).toBe(0)
end)
