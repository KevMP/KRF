--!strict
local Types = require(script.Parent.Parent.types)
local InputTypes = require(script.Parent.Parent.Parent.Input.types)

export type Owner = {
	Record: (Types.ControlLifecycleEvent) -> (),
	Drain: () -> (boolean, string?),
	HasPending: () -> boolean,
	EndCycle: () -> (),
	Destroy: () -> (),
}

local Safety = {}

-- This stores only coalesced mandatory work. Epoch/provenance selection and
-- cancellation are prepared and committed by I1, never mirrored here.
function Safety.new(input: InputTypes.InputOwner, wake: () -> ()): Owner
	local pendingFocus: boolean = false
	local lostFocus: boolean = false
	local pendingDevices: { [Enum.UserInputType]: boolean } = {}
	local disconnected: { [Enum.UserInputType]: boolean } = {}
	local handledFocus: boolean = false
	local handledDevices: { [Enum.UserInputType]: boolean } = {}
	local destroyed: boolean = false

	local function hasPending(): boolean
		return pendingFocus or next(pendingDevices) ~= nil
	end

	return {
		Record = function(event: Types.ControlLifecycleEvent): ()
			if destroyed then
				return
			end

			if event.kind == "FocusGained" then
				lostFocus = false
				input.SetFocusAvailable(true)

				return
			end

			if event.kind == "FocusLost" then
				local repeated: boolean = lostFocus or handledFocus
				lostFocus = true
				input.SetFocusAvailable(false)

				if repeated then
					return
				end

				pendingFocus = true
			elseif event.kind == "DeviceConnected" then
				disconnected[event.device] = nil
				input.SetDeviceAvailable(event.device, true)

				return
			else
				local device: Enum.UserInputType = (event :: { device: Enum.UserInputType }).device

				local repeated: boolean? = disconnected[device] or handledDevices[device]

				disconnected[device] = true
				input.SetDeviceAvailable(device, false)

				if repeated then
					return
				end

				pendingDevices[device] = true
			end

			input.SetSafetyPending(true)
			wake()
		end,
		HasPending = hasPending,
		Drain = function(): (boolean, string?)
			local focus: boolean = pendingFocus
			pendingFocus = false
			local devices: { [Enum.UserInputType]: boolean } = pendingDevices
			pendingDevices = {}
			local selected: { [string]: boolean } = {}

			if focus then
				handledFocus = true

				for inputId in input.GetGraphSnapshot().inputs do
					selected[inputId] = true
				end
			end

			for device in devices do
				handledDevices[device] = true

				for _, inputId in input.GetAffectedDeviceInputs(device) do
					selected[inputId] = true
				end
			end

			local ids: { string } = {}

			for inputId in selected do
				table.insert(ids, inputId)
			end

			table.sort(ids)

			if #ids > 0 then
				local plan: InputTypes.PreparedInputInvalidation?, reason: string? =
					input.PrepareEpochInvalidation(if focus then "FocusLost" else "DeviceDisconnected", ids, true)

				if plan == nil then
					return false, reason
				end

				local accepted: boolean, failure: string? = input.CommitEpochInvalidation(plan, function() end)
				input.ReleasePrepared(plan)

				if not accepted then
					return false, failure
				end
			end

			input.SetSafetyPending(hasPending())

			return true, nil
		end,
		EndCycle = function(): ()
			handledFocus = false
			table.clear(handledDevices)
		end,
		Destroy = function(): ()
			destroyed = true
			pendingFocus = false
			table.clear(pendingDevices)
			table.clear(disconnected)
			input.SetSafetyPending(false)
		end,
	}
end

return Safety
