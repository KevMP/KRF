--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: (string, () -> ()) -> () = (JestGlobals.it :: unknown) :: (string, () -> ()) -> ()
local expect = JestGlobals.expect
local Types = require(KRF.client.Controls.types)
local Native = require(KRF.client.Controls.utils.NativeControlLifecycle)

it("forwards all platform lifecycle signals and disconnects exactly once without stale delivery", function()
	local lost: (() -> ())? = nil
	local gained: (() -> ())? = nil
	local unplugged: ((Enum.UserInputType) -> ())? = nil
	local connected: ((Enum.UserInputType) -> ())? = nil
	local disconnected: number = 0

	local function stop(): ()
		disconnected += 1
	end

	local signals: Types.ControlLifecycleSignals = {
		FocusLost = function(callback): () -> ()
			lost = callback

			return stop
		end,
		FocusGained = function(callback): () -> ()
			gained = callback

			return stop
		end,
		DeviceDisconnected = function(callback): () -> ()
			unplugged = callback

			return stop
		end,
		DeviceConnected = function(callback): () -> ()
			connected = callback

			return stop
		end,
	}

	local events: { Types.ControlLifecycleEvent } = {}

	local release: () -> () = Native.Observe(function(event): ()
		table.insert(events, event)
	end, signals)

	assert(lost, "Expected focus-loss signal")()
	assert(gained, "Expected focus-gain signal")()
	assert(unplugged, "Expected disconnect signal")(Enum.UserInputType.Gamepad1)
	assert(connected, "Expected connect signal")(Enum.UserInputType.Gamepad1)

	expect(events).toEqual({
		{ kind = "FocusLost" },
		{ kind = "FocusGained" },
		{ kind = "DeviceDisconnected", device = Enum.UserInputType.Gamepad1 },
		{ kind = "DeviceConnected", device = Enum.UserInputType.Gamepad1 },
	})

	release()
	release()
	expect(disconnected).toBe(4)
	assert(lost, "Expected retained callback")()
	expect(#events).toBe(4)
end)

it("cleans already-connected native signals when a later subscription fails", function()
	local disconnected: number = 0

	local signals: Types.ControlLifecycleSignals = {
		FocusLost = function(): () -> ()
			return function(): ()
				disconnected += 1
			end
		end,
		FocusGained = function(): () -> ()
			error("NativeSignalUnavailable", 0)
		end,
		DeviceDisconnected = function(): () -> ()
			error("ShouldNotSubscribe", 0)
		end,
		DeviceConnected = function(): () -> ()
			error("ShouldNotSubscribe", 0)
		end,
	}

	local success: boolean, reason: unknown = pcall(Native.Observe, function() end, signals)
	expect({ success, reason }).toEqual({ false, "NativeSignalUnavailable" })
	expect(disconnected).toBe(1)
end)
