--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local KRF = require(ReplicatedStorage.Packages.KRF)

local Controls = {}

local function control(view: KRF.ActorView): ()
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
end

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

	local player: Player = Players.LocalPlayer
	local controlled: KRF.ActorView? = nil

	local function refresh(): ()
		local character: Model? = player.Character
		local view: KRF.ActorView? = if character ~= nil
			then KRF.ActorViewRegistry.GetActorViewByModel(character)
			else nil

		if view ~= nil and view ~= controlled then
			controlled = view
			control(view)
		end
	end

	local function watch(view: KRF.ActorView): ()
		view.OnModelChanged:Connect(refresh)
	end

	KRF.ActorViewRegistry.OnActorViewAdded:Connect(function(view: KRF.ActorView)
		watch(view)
		refresh()
	end)
	KRF.ActorViewRegistry.OnActorViewRemoving:Connect(function(view: KRF.ActorView)
		if view == controlled then
			controlled = nil
		end
	end)
	player.CharacterAdded:Connect(refresh)

	for _, view: KRF.ActorView in KRF.ActorViewRegistry.GetAllActorViews() do
		watch(view)
	end

	refresh()
end

return Controls
