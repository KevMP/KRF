--!strict
local Types = require(script.Parent.AwarenessTypes)

local AwarenessScheduling = {} :: Types.SchedulingModule

function AwarenessScheduling.GetBudget(): Types.StepBudget
	error("N4NotImplemented:AwarenessScheduling.GetBudget")
end

function AwarenessScheduling.ObserveStep(_callback: () -> ()): () -> ()
	error("N4NotImplemented:AwarenessScheduling.ObserveStep")
end

return AwarenessScheduling
