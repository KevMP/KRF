--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local KRF = require(ReplicatedStorage.Packages.KRF)

local ChannelHealRequirements: KRF.ActionPredictionPolicy = {
	blockedTags = { "Stunned" },
}

return ChannelHealRequirements
