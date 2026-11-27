--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local PresentationTypes = require(ReplicatedStorage.Packages.KRF.client.Presentation.types)

local requirements: PresentationTypes.ActionPredictionPolicy = {
	requiredTags = { "Status.Grounded" },
	blockedTags = { "Status.Stunned" },
	resourceRequirements = { Mana = { min = 30 } },
	costs = { Mana = 20 },
}

return requirements
