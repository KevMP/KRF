--!strict
local Types = require(script.Parent.Parent.types)
local RunService = game:GetService("RunService")
local Constants = require(script.Parent.Parent.Parent.Parent.shared.Networking.utils.ActorProtocolConstants)

local AwarenessScheduling = {} :: Types.AwarenessSchedulingModule

function AwarenessScheduling.GetBudget(): Types.AwarenessStepBudget
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
