--!strict
local Types = require(script.Parent.Parent.types)
local State = require(script.Parent.ClientActionRuntimeState)
local Requests = require(script.Parent.Parent.Parent.ActionRequest.utils.ClientActionRequestState)
local RequestTypes = require(script.Parent.Parent.Parent.ActionRequest.types)
local Observation = require(script.Parent.ActionRequestObservation)

local Installation = {}

-- The subscription outlives route/input teardown, so command Closing can still
-- publish the original pending outcomes. Client disposes it after Networking.
function Installation.Install(now: () -> number): (() -> (), () -> ())
	-- A previous connection may still be finishing teardown. Do not adopt its
	-- global request owner while this incarnation is still awaiting Bootstrap.
	local requests: RequestTypes.ClientActionRequestRuntime? = nil

	local owner: Types.ActionObservationOwner = Observation.new({
		Now = now,
		Publish = State.NotifyActionRequest,
		Report = function(reason: string): ()
			warn("[ActionObservation] " .. reason)
		end,
	})

	local previous: Types.ActionObservationOwner? = State.GetObservations()

	if previous ~= nil then
		previous.Destroy()
		State.DisconnectActionRequests()
	end

	State.InstallObservations(owner)
	local active: boolean = true

	local function cleanup(): ()
		if not active then
			return
		end

		active = false

		local function dispose(): ()
			owner.Destroy()

			if State.GetObservations() == owner then
				State.InstallObservations(nil)
				State.DisconnectActionRequests()
			end
		end

		if requests ~= nil then
			requests:AfterObservations(dispose)
		else
			dispose()
		end
	end

	local function bindRequests(): ()
		if not active or State.GetObservations() ~= owner then
			return
		end

		local installed: RequestTypes.ClientActionRequestRuntime =
			assert(Requests.Get(), "ActionRequestRuntimeUnavailable")

		owner.SetRequests(installed)
		requests = installed
	end

	return cleanup, bindRequests
end

-- Invalid configuration can fail before an owner is installed. Clear only an
-- unowned Event; a still-finishing old generation owns its own fenced cleanup.
function Installation.ClearUninstalled(): ()
	if State.GetObservations() == nil then
		State.DisconnectActionRequests()
	end
end

return Installation
