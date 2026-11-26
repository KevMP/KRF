--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local KRF = require(ReplicatedStorage.Packages.KRF)

--@example 1

local Inventory: KRF.ControllerDefinition = {
	key = "Inventory",
	factory = function(_actor: KRF.Actor): KRF.Controller
		--@example 2

		return inventory
	end,
}

return Inventory
