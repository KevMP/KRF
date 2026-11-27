--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("KRF"))

local accepted: boolean = KRF.Assets.Preload(
	{ { kind = "Sound", assetId = "rbxassetid://1" } },
	function(_report: KRF.PreloadReport): ()
		Players.LocalPlayer:SetAttribute("AbandonedPreloadCompleted", true)
	end
)

Players.LocalPlayer:SetAttribute("AbandonedPreloadAccepted", accepted)
script:Destroy()
