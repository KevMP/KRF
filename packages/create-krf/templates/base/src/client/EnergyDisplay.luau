--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local KRF = require(ReplicatedStorage.Packages.KRF)
local LocalCharacter = require(script.Parent.LocalCharacter)

local EnergyDisplay = {}

function EnergyDisplay.Start(): ()
	local player: Player = Players.LocalPlayer

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

	gui.Parent = player:WaitForChild("PlayerGui")

	RunService.RenderStepped:Connect(function()
		local view: KRF.ActorView? = LocalCharacter.Get()

		if view == nil then
			return
		end

		local resources: KRF.ResourcesView = view:GetResources()
		local current: number = resources:GetCurrent("Energy") or 0
		local max: number = resources:GetMax("Energy") or 0
		local text: string = `Energy {math.floor(current)}/{max}`

		if label.Text ~= text then
			label.Text = text
		end
	end)
end

return EnergyDisplay
