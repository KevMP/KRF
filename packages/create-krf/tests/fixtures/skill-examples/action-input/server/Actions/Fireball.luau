--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local KRF = require(ReplicatedStorage.Packages.KRF)

--@example 7

local function Fireball(): KRF.ActionDefinition
	return {
		id = "Fireball",
		visibility = "ClientVisible",
		costs = { Mana = 20 },
		onCanStart = targetInRange,
		onStart = function(context: KRF.ActionExecutionContext): ()
			context:End()
		end,
	}
end

return Fireball
