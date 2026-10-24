--!strict
local Types = require(script.Parent.Parent.types)
local Constants = require(script.Parent.Parent.Parent.Parent.shared.Networking.utils.ActorProtocolConstants)

export type Unit = "connections" | "streams" | "checks" | "prepares" | "measurements" | "encodes" | "sends" | "captures"
export type Budget = { limits: { [string]: number }, used: { [string]: number } }

local ReliableWorkBudget = {}

function ReliableWorkBudget.new(records: number, overrides: Types.ReliableWorkLimits?): Budget
	local limits = {
		connections = records * Constants.VISITS_PER_RECORD,
		streams = records * Constants.VISITS_PER_RECORD,
		checks = records * Constants.VISITS_PER_RECORD,
		prepares = records * Constants.VISITS_PER_RECORD,
		measurements = records * Constants.VISITS_PER_RECORD,
		encodes = records,
		sends = records,
		captures = Constants.STEP_CAPTURES,
	}

	local used: { [string]: number } = {}

	for key, value in limits do
		local override = if overrides ~= nil then overrides[key] else nil

		limits[key] = override or value
		assert(limits[key] >= 0 and limits[key] < math.huge and limits[key] % 1 == 0, "InvalidReliableWorkLimit")
		used[key] = 0
	end

	return { limits = limits, used = used }
end

function ReliableWorkBudget.Available(budget: Budget, unit: Unit): boolean
	return budget.used[unit] < budget.limits[unit]
end

function ReliableWorkBudget.Take(budget: Budget, unit: Unit): boolean
	if not ReliableWorkBudget.Available(budget, unit) then
		return false
	end

	budget.used[unit] += 1

	return true
end

return ReliableWorkBudget
