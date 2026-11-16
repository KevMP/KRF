--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local KRF = require(ReplicatedStorage.Packages.KRF)
local LocalActor = require(script.Parent.LocalActor)

local EnergyDisplay = {}

function EnergyDisplay.Start(): ()
	local gui: ScreenGui = Instance.new("ScreenGui")
	gui.Name = "EnergyDisplay"
	gui.ResetOnSpawn = false

	local label: TextLabel = Instance.new("TextLabel")
	label.Name = "Energy"
	label.Position = UDim2.new(0, 16, 1, -56)
	label.Size = UDim2.fromOffset(160, 40)
	label.BackgroundColor3 = Color3.new(0, 0, 0)
	label.BackgroundTransparency = 0.4
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextSize = 20
	label.Text = "Energy"
	label.Parent = gui

	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")

	local resources: KRF.ResourcesView? = nil

	LocalActor.Observe(function(view: KRF.ActorView)
		resources = view:GetResources()
	end)

	RunService.RenderStepped:Connect(function()
		if resources ~= nil then
			local current: number = resources:GetCurrent("Energy") or 0
			local max: number = resources:GetMax("Energy") or 0
			label.Text = `Energy {math.floor(current)}/{max}`
		end
	end)
end

return EnergyDisplay
