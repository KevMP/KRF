--!strict
local Types = require(script.Parent.Parent.types)
local State = require(script.Parent.ClientActionRuntimeState)
local Requests = require(script.Parent.Parent.Parent.ActionRequest.utils.ClientActionRequestState)
local Observation = require(script.Parent.ActionRequestObservation)

local Installation = {}

-- The subscription outlives route/input teardown, so command Closing can still
-- publish the original pending outcomes. Client disposes it after Networking.
function Installation.Install(now: () -> number): () -> ()
	local requests = assert(Requests.Get(), "ActionRequestRuntimeUnavailable")

	local owner: Types.ActionObservationOwner = Observation.new({
		Requests = requests,
		Now = now,
		Publish = State.NotifyActionRequest,
		Report = function(reason: string): ()
			warn("[ActionObservation] " .. reason)
		end,
	})

	local previous: Types.ActionObservationOwner? = State.GetObservations()

	if previous ~= nil then
		previous.Destroy()
	end

	State.InstallObservations(owner)
	local active: boolean = true

	return function(): ()
		if not active then
			return
		end

		active = false

		requests:AfterObservations(function(): ()
			owner.Destroy()

			if State.GetObservations() == owner then
				State.InstallObservations(nil)
				State.DisconnectActionRequests()
			end
		end)
	end
end

return Installation
