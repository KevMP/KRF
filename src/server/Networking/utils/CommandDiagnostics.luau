--!strict
local Types = require(script.Parent.Parent.Parent.Parent.shared.Networking.types)
local Metrics = require(script.Parent.Parent.Parent.Parent.shared.Networking.utils.NetworkingMetrics)

-- One bounded observation on the dispatch stack. Fault/reentrancy cleanup can
-- encounter the same request twice; it must not count two affected commands.
-- These flags never control execution, admission, history or result ownership.
export type Observation = { owner: Types.DiagnosticCollector?, faulted: boolean, uncertain: boolean }

local CommandDiagnostics = {}

function CommandDiagnostics.new(owner: Types.DiagnosticCollector?): Observation
	return { owner = owner, faulted = false, uncertain = false }
end

function CommandDiagnostics.Fault(observation: Observation): ()
	if not observation.faulted then
		observation.faulted = true
		Metrics.Count(observation.owner, "commandsFaulted", 1)
	end
end

function CommandDiagnostics.Uncertain(observation: Observation): ()
	if not observation.uncertain then
		observation.uncertain = true
		Metrics.Count(observation.owner, "commandsUncertain", 1)
	end
end

return CommandDiagnostics
