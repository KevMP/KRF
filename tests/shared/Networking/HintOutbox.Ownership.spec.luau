--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local Outbox = require(KRF.shared.Networking.utils.HintOutbox)
local Metrics = require(KRF.shared.Networking.utils.NetworkingMetrics)
local Types = require(KRF.shared.Networking.types)

local newOutbox: (Outbox.Pool, Types.DiagnosticCollector?, () -> number) -> Outbox.State<string> = Outbox.new

it("keeps selected bytes owned through retirement and repeated cleanup without debiting a replacement", function()
	local pool = Outbox.pool()
	local owner = Metrics.new("Server")

	local function now(): number
		return 1
	end

	local previous = newOutbox(pool, owner, now)
	Outbox.Admit(previous, "sample", "Actor", 1, buffer.fromstring("first"), 1, 0)
	Outbox.Admit(previous, "sample", "Actor", 1, buffer.fromstring("new"), 2, 0)

	local batch = Outbox.Select(previous, 1, 900, function(): boolean
		return true
	end)

	expect(batch.work).toBe(1)
	expect(buffer.tostring(batch.records[1])).toBe("new")
	expect(previous.latest.sample.sequence).toBe(2)
	expect(previous.latest.sample.job).toBeNil()
	Outbox.ForgetActor(previous, "Actor")
	Outbox.Destroy(previous)
	Outbox.Destroy(previous)
	expect(pool.pendingCount).toBe(1)
	expect(pool.pendingBytes).toBe(3)
	expect(pool.latestCount).toBe(0)
	local replacement = newOutbox(pool, owner, now)
	Outbox.Admit(replacement, "sample", "Actor", 1, buffer.fromstring("next"), 1, 1)
	Outbox.Settle(previous, batch)
	Outbox.Settle(previous, batch)
	expect(pool.pendingCount).toBe(1)
	expect(pool.pendingBytes).toBe(4)
	expect(pool.latestCount).toBe(1)
	expect(owner:Snapshot().gauges.hintSendRecords.current).toBe(1)
	expect(owner:Snapshot().counters.hintsCoalesced).toBe(1)
	Outbox.Destroy(replacement)
	expect(pool.pendingCount).toBe(0)
	expect(pool.pendingBytes).toBe(0)
	expect(owner:Snapshot().gauges.hintSendRecords.current).toBe(0)
end)
