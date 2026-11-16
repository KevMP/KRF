--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local KRF = require(ReplicatedStorage.Packages.KRF)
local LocalActor = require(script.Parent.LocalActor)

local Controls = {}

function Controls.Start(): ()
	assert(KRF.ClientControls.Apply({
		inputs = {
			{
				kind = "Set",
				sourceId = "Gameplay",
				definition = {
					contexts = { Gameplay = { priority = 1000, sink = false } },
					inputs = {
						Focus = {
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
	}))

	LocalActor.Observe(function(view: KRF.ActorView)
		assert(KRF.ClientControls.Apply({
			profiles = {
				{
					kind = "Set",
					actor = view,
					sourceId = "Gameplay",
					profile = {
						routes = {
							{
								when = { kind = "Input", inputId = "Focus", gesture = "Pressed" },
								target = { kind = "Fixed", actionId = "Focus" },
							},
						},
					},
				},
			},
			selection = { kind = "Set", actor = view },
		}))
	end)
end

return Controls
