--!strict
local Types = require(script.Parent.Parent.types)
local DeviceInputs = require(script.Parent.InputDeviceInputs)

export type Owner = {
	SetFocus: (boolean) -> (),
	SetDevice: (Enum.UserInputType, boolean) -> (),
	Reconcile: () -> (),
	IsAvailable: (string) -> boolean,
}

local Availability = {}

-- Cached availability is configuration-time work. Native dispatch reads one
-- lookup; availability changes never manufacture a physical neutral event.
function Availability.new(current: () -> Types.InputGraphSnapshot): Owner
	local focused: boolean = true
	local disconnected: { [Enum.UserInputType]: boolean } = {}
	local blocked: { [string]: boolean } = {}

	local function reconcile(): ()
		blocked = {}

		for device in disconnected do
			for _, inputId in DeviceInputs.Affected(current(), device) do
				blocked[inputId] = true
			end
		end
	end

	return {
		SetFocus = function(available: boolean): ()
			focused = available
		end,
		SetDevice = function(device: Enum.UserInputType, available: boolean): ()
			disconnected[device] = if available then nil else true
			reconcile()
		end,
		Reconcile = reconcile,
		IsAvailable = function(inputId: string): boolean
			return focused and not blocked[inputId]
		end,
	}
end

return Availability
