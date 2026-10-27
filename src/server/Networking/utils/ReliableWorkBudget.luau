--!strict
local Types = require(script.Parent.Parent.types)
local SharedTypes = require(script.Parent.Parent.Parent.Parent.shared.Networking.types)
local Metrics = require(script.Parent.Parent.Parent.Parent.shared.Networking.utils.NetworkingMetrics)
local Constants = require(script.Parent.Parent.Parent.Parent.shared.Networking.utils.ActorProtocolConstants)

export type Unit =
	"connections"
	| "streams"
	| "checks"
	| "prepares"
	| "measurements"
	| "encodes"
	| "sends"
	| "captures"
	| "priorities"

-- Work is indexed by its closed unit set, never arbitrary configuration keys.
type Counts = { [Unit]: number }

export type Budget = {
	diagnostics: SharedTypes.DiagnosticCollector?,
	connection: SharedTypes.DiagnosticCollector?,
	total: number,
	byConnection: { [SharedTypes.DiagnosticCollector]: number },
	limits: Counts,
	used: Counts,
}

local ReliableWorkBudget = {}

local counters: { [Unit]: SharedTypes.DiagnosticCounter } = {
	streams = "reliableStreamVisits",
	checks = "reliableChecks",
	prepares = "reliablePrepares",
	measurements = "reliableMeasurements",
	encodes = "reliableEncodes",
	captures = "reliableCaptures",
	priorities = "reliablePriorityVisits",
}

function ReliableWorkBudget.new(
	records: number,
	overrides: Types.ReliableWorkLimits?,
	diagnostics: SharedTypes.DiagnosticCollector?
): Budget
	local limits: Counts = {
		connections = (overrides and overrides.connections) or records * Constants.VISITS_PER_RECORD,
		streams = (overrides and overrides.streams) or records * Constants.VISITS_PER_RECORD,
		checks = (overrides and overrides.checks) or records * Constants.VISITS_PER_RECORD,
		prepares = (overrides and overrides.prepares) or records * Constants.VISITS_PER_RECORD,
		measurements = (overrides and overrides.measurements) or records * Constants.VISITS_PER_RECORD,
		encodes = (overrides and overrides.encodes) or records,
		sends = (overrides and overrides.sends) or records,
		captures = (overrides and overrides.captures) or Constants.STEP_CAPTURES,
		priorities = (overrides and overrides.priorities) or 1,
	}

	local used: Counts = {
		connections = 0,
		streams = 0,
		checks = 0,
		prepares = 0,
		measurements = 0,
		encodes = 0,
		sends = 0,
		captures = 0,
		priorities = 0,
	}

	for _, value in limits do
		assert(value >= 0 and value < math.huge and value % 1 == 0, "InvalidReliableWorkLimit")
	end

	return { diagnostics = diagnostics, total = 0, byConnection = {}, limits = limits, used = used }
end

function ReliableWorkBudget.Available(budget: Budget, unit: Unit): boolean
	return budget.used[unit] < budget.limits[unit]
end

function ReliableWorkBudget.Take(budget: Budget, unit: Unit): boolean
	local used = budget.used[unit]

	if used >= budget.limits[unit] then
		return false
	end

	budget.used[unit] = used + 1
	budget.total += 1

	local owner = budget.connection

	if unit ~= "connections" then
		local key = counters[unit]

		if key ~= nil then
			Metrics.Count(owner or budget.diagnostics, key, 1)
		end

		if owner ~= nil then
			local count = (budget.byConnection[owner] or 0) + 1

			budget.byConnection[owner] = count
			Metrics.Observe(owner, "reliablePumpWorkUnits", count)
		end
	end

	Metrics.Observe(budget.diagnostics, "reliablePumpWorkUnits", budget.total)

	return true
end

return ReliableWorkBudget
