--!strict
local Types = require(script.Parent.AwarenessTypes)
local RunService = game:GetService("RunService")
local Constants = require(script.Parent.Parent.Parent.shared.Networking.ActorProtocolConstants)

local AwarenessScheduling = {} :: Types.SchedulingModule

function AwarenessScheduling.GetBudget(): Types.StepBudget
	return { maxBytes = Constants.STEP_BYTES, maxRecords = Constants.STEP_RECORDS }
end

function AwarenessScheduling.ObserveStep(callback: () -> ()): () -> ()
	local connection: RBXScriptConnection = RunService.Heartbeat:Connect(function(_deltaTime: number)
		callback()
	end)
	return function(): ()
		connection:Disconnect()
	end
end

return AwarenessScheduling
