--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local Types = require(KRF.server.Networking.types)
local History = require(KRF.server.Networking.utils.CommandOutcomeHistory)
local Metrics = require(KRF.shared.Networking.utils.NetworkingMetrics)
local Clock = require(script.Parent.Parent.Parent.shared.Utils.TestClock)

it("evicts by retained bytes and expires quiescent prior outcomes without retaining timers", function()
	local clock = Clock.new()
	local owner = Metrics.new("Connection")
	local history: History.Runtime = History.new(owner, clock.Now, clock.Schedule, 3, 10, 5)
	local first: Types.CommandOutcome = { requestId = 1, commandId = "First", status = "Accepted" }
	table.freeze(first)
	local second: Types.CommandOutcome = { requestId = 2, commandId = "Second", status = "Rejected" }
	table.freeze(second)
	history:Retain(first, 6)
	clock.Advance(1)
	history:Retain(second, 6)
	expect(history:Get(1)).toBeNil()
	expect(history:Get(2)).toBe(second)
	expect(owner:Snapshot().gauges.commandHistoryBytes.current).toBe(6)
	expect(clock.Count()).toBe(1)
	clock.Advance(5)
	expect(history:Get(2)).toBeNil()
	expect(owner:Snapshot().gauges.commandHistoryEntries.current).toBe(0)
	expect(owner:Snapshot().gauges.commandHistoryBytes.current).toBe(0)
	expect(clock.Count()).toBe(0)
	history:Destroy()
end)

it("ignores an old expiry callback after disconnect without debiting a replacement history", function()
	local aggregate = Metrics.new("Server")
	local previousOwner = Metrics.new("Connection", aggregate)
	local replacementOwner = Metrics.new("Connection", aggregate)
	local pending: { () -> () } = {}
	local cancellations = 0

	local function schedule(_seconds: number, callback: () -> ()): () -> ()
		table.insert(pending, callback)

		return function(): ()
			cancellations += 1
		end
	end

	local function now(): number
		return 0
	end

	local outcome: Types.CommandOutcome = { requestId = 1, commandId = "First", status = "Accepted" }
	table.freeze(outcome)
	local previous: History.Runtime = History.new(previousOwner, now, schedule, 2, 20, 5)
	previous:Retain(outcome, 8)
	previous:Destroy()
	previous:Destroy()
	local replacement: History.Runtime = History.new(replacementOwner, now, schedule, 2, 20, 5)
	replacement:Retain(outcome, 8)
	pending[1]()
	expect(#pending).toBe(2)
	expect(cancellations).toBe(1)
	expect(previous:Get(1)).toBeNil()
	expect(replacement:Get(1)).toBe(outcome)
	expect(aggregate:Snapshot().gauges.commandHistoryEntries.current).toBe(1)
	expect(aggregate:Snapshot().gauges.commandHistoryBytes.current).toBe(8)
	replacement:Destroy()
	expect(cancellations).toBe(2)
	expect(aggregate:Snapshot().gauges.commandHistoryBytes.current).toBe(0)
end)
