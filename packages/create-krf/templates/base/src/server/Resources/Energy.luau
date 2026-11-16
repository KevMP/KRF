--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local KRF = require(ReplicatedStorage.Packages.KRF)

local Energy: KRF.ResourceDefinition = {
	id = "Energy",
	max = { value = 100 },
	initialValue = 0,
	regen = { rate = { propertyName = "EnergyRegen", defaultBaseValue = 0 } },
	visibility = "ClientVisible",
	autoAssign = true,
}

return Energy
