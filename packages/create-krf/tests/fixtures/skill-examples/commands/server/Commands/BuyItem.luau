--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local KRF = require(ReplicatedStorage.Packages.KRF)
local Inventory = require(script.Parent.Parent.Controllers.Inventory)
local Items = require(script.Parent.Parent.Items)

local BuyItem: KRF.CommandDefinition = {
	id = "BuyItem",
	target = "Actor",
	request = KRF.Schema.Struct({
		ItemId = KRF.Schema.String(32),
	}),
	authorize = KRF.CommandAuthorization.OwnerActor,
	--@example 1
}

return BuyItem
