--!strict
local UserInputService = game:GetService("UserInputService")
local Types = require(script.Parent.Parent.types)
local Native = {}

local function connect<Args...>(signal: RBXScriptSignal, callback: (Args...) -> ()): () -> ()
	local connection: RBXScriptConnection = signal:Connect(callback)

	return function(): ()
		connection:Disconnect()
	end
end

local defaults: Types.ControlLifecycleSignals = {
	FocusLost = function(callback: () -> ()): () -> ()
		return connect(UserInputService.WindowFocusReleased, callback)
	end,
	FocusGained = function(callback: () -> ()): () -> ()
		return connect(UserInputService.WindowFocused, callback)
	end,
	DeviceDisconnected = function(callback: (Enum.UserInputType) -> ()): () -> ()
		return connect(UserInputService.GamepadDisconnected, callback)
	end,
	DeviceConnected = function(callback: (Enum.UserInputType) -> ()): () -> ()
		return connect(UserInputService.GamepadConnected, callback)
	end,
}

-- Tests inject only platform signals; owner installation and safety remain real.
function Native.Observe(
	callback: (Types.ControlLifecycleEvent) -> (),
	signals: Types.ControlLifecycleSignals?
): () -> ()
	local sources: Types.ControlLifecycleSignals = signals or defaults
	local disconnects: { () -> () } = {}
	local active: boolean = true

	local function stop(): ()
		if not active then
			return
		end

		active = false

		for _, disconnect in disconnects do
			disconnect()
		end

		table.clear(disconnects)
	end

	local function notify(event: Types.ControlLifecycleEvent): ()
		if active then
			callback(event)
		end
	end

	local success: boolean, reason: unknown = pcall(function(): ()
		table.insert(
			disconnects,
			sources.FocusLost(function(): ()
				notify({ kind = "FocusLost" })
			end)
		)

		table.insert(
			disconnects,
			sources.FocusGained(function(): ()
				notify({ kind = "FocusGained" })
			end)
		)

		table.insert(
			disconnects,
			sources.DeviceDisconnected(function(device: Enum.UserInputType): ()
				notify({ kind = "DeviceDisconnected", device = device })
			end)
		)

		table.insert(
			disconnects,
			sources.DeviceConnected(function(device: Enum.UserInputType): ()
				notify({ kind = "DeviceConnected", device = device })
			end)
		)
	end)

	if not success then
		stop()
		error(reason, 0)
	end

	return stop
end

return Native
