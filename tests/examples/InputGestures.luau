--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage.Packages.KRF.client.Input.types)
local Input: Types.InputRuntime = require(ReplicatedStorage.Packages.KRF.client.Input.InputRuntime)

local Gestures = {}

-- Call after Client.Init and InputControls.Install. PreferSpecific emits a Tap
-- immediately on release; DeferredTap waits for the inclusive double gap to close.
-- Both preserve native Pressed/Released. Neither executes an Action.
function Gestures.Install(policy: Types.DoubleTapArbitration): ()
	local success: boolean, reason: string? = Input.SetSource("Game.Gestures", {
		gestures = {
			Primary = {
				Tap = { maxDurationSeconds = 0.25 },
				Held = { afterSeconds = 0.5 },
				LongHeld = { afterSeconds = 1 },
				DoubleTapped = { maxTapDurationSeconds = 0.25, maxGapSeconds = 0.5, arbitration = policy },
			},
		},
	})

	assert(success, reason or "GestureInstallationFailed")
end

function Gestures.Remove(): ()
	local success: boolean, reason: string? = Input.RemoveSource("Game.Gestures")
	assert(success, reason or "GestureRemovalFailed")
end

return Gestures
