--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local KRF = require(ReplicatedStorage.Packages.KRF)

local Focused: KRF.TagDefinition = {
	id = "Focused",
	duplicateBehavior = "Ignore",
	visibility = "ClientVisible",
	properties = { EnergyRegen = { add = 10 } },
}

return Focused
