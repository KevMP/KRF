--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local Constants = require(KRF.shared.Networking.utils.ActorProtocolConstants)

local Scenario = {}
Scenario.populations = { { actors = 30, players = 10 }, { actors = 75, players = 25 }, { actors = 90, players = 30 } }
Scenario.modes = { "Ordinary", "Heavy", "Burst" }
Scenario.ticks = 180
Scenario.hz = 30
Scenario.clients = 2

-- Fixture-only overrides: both comparison arms use the same captured values.
function Scenario.budget(): (number, number)
	local records = ReplicatedStorage:FindFirstChild("NetworkingBenchmarkRecords") :: IntValue?
	local bytes = ReplicatedStorage:FindFirstChild("NetworkingBenchmarkBytes") :: IntValue?

	return if bytes ~= nil then bytes.Value else Constants.STEP_BYTES,
		if records ~= nil then records.Value else Constants.STEP_RECORDS
end

function Scenario.activeCount(runtime: any): number
	return if runtime.active.count ~= nil then runtime.active.count else #runtime.active
end

function Scenario.work(runtime: any): any
	if runtime.active.count == nil then
		return nil -- Legacy implementation has no attempted-work accounting.
	end

	if runtime.work ~= nil then
		for unit, used in runtime.work.used do
			assert(used <= runtime.work.limits[unit], "Scheduler exceeded attempted-work limit: " .. unit)
		end
	end

	return if runtime.work ~= nil then table.clone(runtime.work.used) else {}
end

function Scenario.plan(count: number, mode: string): { { number } }
	local plan: { { number } } = {}

	for tick = 1, Scenario.ticks do
		local selected: { number } = {}

		for index = 1, count do
			local fighting = index <= math.floor(count * (if mode == "Heavy" then 0.5 else 0.2))
			local light = index > math.floor(count * 0.5) and index <= math.floor(count * 0.8)
			local period = if fighting then (if mode == "Heavy" then 3 else 6) else 30
			local burst = mode == "Burst" and tick % 30 == 0 and index <= math.min(30, math.floor(count / 2))

			if burst or ((fighting or light) and (tick + index) % period == 0) then
				table.insert(selected, index)
			end
		end

		table.insert(plan, selected)
	end

	return plan
end

function Scenario.counts(plan: { { number } }, count: number): { number }
	local counts: { number } = table.create(count, 0)

	for _, indices in plan do
		for _, index in indices do
			counts[index] += 1
		end
	end

	return counts
end

function Scenario.summarize(values: { number }): any
	local sorted = table.clone(values)
	table.sort(sorted)
	local total, negative = 0, 0

	for _, value in sorted do
		total += value
		negative += if value < 0 then 1 else 0
	end

	return {
		count = #sorted,
		median = sorted[math.max(1, math.ceil(#sorted * 0.5))] or 0,
		p95 = if #sorted >= 20 then sorted[math.ceil(#sorted * 0.95)] else nil,
		p99 = if #sorted >= 100 then sorted[math.ceil(#sorted * 0.99)] else nil,
		max = sorted[#sorted] or 0,
		mean = if #sorted > 0 then total / #sorted else 0,
		total = total,
		negativeSamples = negative,
	}
end

function Scenario.verify(state: any, index: number): ()
	assert(table.isfrozen(state), "Mutable installed Tags")
	local count = 0

	for id, entry in state do
		count += 1
		local tagIndex = tonumber(string.match(id, "^Bench.Tag(%d)$"))
		assert(tagIndex ~= nil and tagIndex <= 1 + (index - 1) % 5, "Unexpected or private Tag")
		assert(table.isfrozen(entry), "Mutable Tag entry")
		assert(entry.stackCount == (if tagIndex == 1 then 1 else 1 + (index + tagIndex) % 3), "Wrong stacks")
		assert(math.isfinite(entry.expiresAt), "Missing timing anchor")
	end

	assert(count == 1 + (index - 1) % 5, "Missing Tags")
end

return Scenario
