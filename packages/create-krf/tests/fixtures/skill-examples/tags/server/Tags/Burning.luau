--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local KRF = require(ReplicatedStorage.Packages.KRF)

local Burning: KRF.TagDefinition = {
	id = "Burning",
	visibility = "ClientVisible",
	duplicateBehavior = "Refresh",
	duration = 3,
	tickInterval = 1,
	--@example 2
}

return Burning
