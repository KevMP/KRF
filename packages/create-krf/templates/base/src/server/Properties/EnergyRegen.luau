--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local KRF = require(ReplicatedStorage.Packages.KRF)

local EnergyRegen: KRF.PropertyDefinition = {
	id = "EnergyRegen",
	defaultBaseValue = 0,
}

return EnergyRegen
