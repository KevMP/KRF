--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local KRF = require(ReplicatedStorage.Packages.KRF)

local keybinds: KRF.ControlChangeSet = {
	inputs = {
		{
			kind = "Set",
			sourceId = "Keybinds",
			definition = {
				contexts = { Gameplay = { priority = 1000, sink = false } },
				inputs = {
					AbilitySlot1 = {
						context = "Gameplay",
						type = Enum.InputActionType.Bool,
						bindings = {
							Keyboard = { keyCode = Enum.KeyCode.F },
							Gamepad = { keyCode = Enum.KeyCode.ButtonX },
						},
					},
				},
			},
		},
	},
	contexts = { { contextId = "Gameplay", enabled = true } },
}

return keybinds
