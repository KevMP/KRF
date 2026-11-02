--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage.Packages.KRF.client.Input.types)
local Input: Types.InputRuntime = require(ReplicatedStorage.Packages.KRF.client.Input.InputRuntime)

local Controls = {}

function Controls.Install(button: GuiButton, label: InputActionLabel): ()
	assert(
		Input.SetSource("Game.Controls", {
			contexts = { Gameplay = { priority = 2000, sink = true } },
			inputs = {
				Primary = {
					context = "Gameplay",
					type = Enum.InputActionType.Bool,
					displayName = "Primary attack",
					bindings = {
						Keyboard = { keyCode = Enum.KeyCode.Q, displayName = "Charge" },
						Gamepad = { keyCode = Enum.KeyCode.ButtonR2, pressedThreshold = 0.8, releasedThreshold = 0.2 },
						Touch = { uiButton = button },
					},
				},
			},
		}),
		"Input source installation failed"
	)

	assert(Input.BindActionLabel("Primary", label), "Input label binding failed")
	assert(Input.SetContextEnabled("Gameplay", true), "Context enablement failed")
end

function Controls.Remap(): ()
	assert(
		Input.SetSource("Player.Keybinds", {
			priority = 1000,
			bindingOverrides = { Primary = { Keyboard = { keyCode = Enum.KeyCode.E } } },
		}),
		"Input source installation failed"
	)
end

function Controls.Restore(): ()
	assert(Input.RemoveSource("Player.Keybinds"), "Input source removal failed")
end

function Controls.Remove(): ()
	Controls.Restore()
	assert(Input.RemoveSource("Game.Controls"), "Input source removal failed")
end

return Controls
