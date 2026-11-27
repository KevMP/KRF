--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local KRF = require(ReplicatedStorage.Packages.KRF)

local FireballRequirements: KRF.ActionPredictionPolicy = {
	requiredTags = { "Grounded" },
	costs = { Mana = 20 },
}

return FireballRequirements
