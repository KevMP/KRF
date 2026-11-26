--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local KRF = require(ReplicatedStorage.Packages.KRF)

export type Inventory = KRF.Controller & {
	HasRoom: (itemId: string, count: number) -> boolean,
	AddItem: (itemId: string, count: number) -> (),
}

local Inventory: KRF.ControllerDefinition = {
	key = "Inventory",
	factory = function(_actor: KRF.Actor): KRF.Controller
		local items: { [string]: number } = {}
		local inventory: Inventory = {
			HasRoom = function(_itemId: string, _count: number): boolean
				return true
			end,
			AddItem = function(itemId: string, count: number): ()
				items[itemId] = (items[itemId] or 0) + count
			end,
			Destroy = function(): () end,
		}

		return inventory
	end,
}

return Inventory
