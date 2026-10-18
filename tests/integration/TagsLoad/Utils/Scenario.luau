--!strict
local Scenario = {}
Scenario.actorCounts = { 25, 50, 100 }
Scenario.clients = 2
Scenario.steadyRounds = 12
Scenario.burstRounds = 3
Scenario.intervalSeconds = 0.2

local baseCounts: { [string]: number } = {
	["State.Alive"] = 1,
	["State.Combat"] = 1,
	["Movement.Grounded"] = 1,
	["Buff.Haste"] = 1,
	["Buff.Fortified"] = 1,
	["Buff.Regeneration"] = 1,
	["Status.Burning"] = 3,
	["Status.Poison"] = 2,
	["Buff.Combo"] = 1,
}

Scenario.baseCounts = table.freeze(baseCounts)

function Scenario.summarize(values: { number }): { [string]: number }
	local sorted: { number } = table.clone(values)
	table.sort(sorted)
	local total: number = 0
	local negative: number = 0

	for _, value: number in sorted do
		total += value

		if value < 0 then
			negative += 1
		end
	end

	return {
		count = #sorted,
		min = sorted[1] or 0,
		median = sorted[math.max(1, math.ceil(#sorted / 2))] or 0,
		p95 = sorted[math.max(1, math.ceil(#sorted * 0.95))] or 0,
		max = sorted[#sorted] or 0,
		mean = if #sorted > 0 then total / #sorted else 0,
		negativeSamples = negative,
	}
end

function Scenario.verifyState(state: any, generation: number): ()
	assert(type(state) == "table" and table.isfrozen(state), "Expected immutable installed domain truth")
	local count: number = 0

	for id: string, entry: any in state do
		count += 1
		local expected: number? = Scenario.baseCounts[id]

		if id == "Buff.Combo" then
			expected = 1 + generation
		elseif id == "Status.Stunned" and generation % 2 == 1 then
			expected = 1
		end

		assert(expected ~= nil and entry.stackCount == expected, "Unexpected aggregate for " .. id)
		assert(table.isfrozen(entry), "Mutable installed Tag entry")

		for field: string in entry do
			assert(field == "stackCount" or field == "expiresAt", "Unexpected replicated Tag field")
		end

		if id == "State.Alive" or id == "State.Combat" or id == "Movement.Grounded" or id == "Buff.Combo" then
			assert(entry.expiresAt == nil, "Indefinite Tag acquired a timer")
		else
			assert(type(entry.expiresAt) == "number" and math.isfinite(entry.expiresAt), "Missing finite timing anchor")
		end
	end

	assert(count == 9 + generation % 2, "Missing or leaked active Tag IDs")
end

return Scenario
