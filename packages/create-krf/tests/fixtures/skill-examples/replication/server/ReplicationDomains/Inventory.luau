--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local KRF = require(ReplicatedStorage.Packages.KRF)

--@example 3

local InventoryDomain: KRF.ReplicationDomainDefinition = {
	id = "Inventory",
	state = KRF.Schema.Struct({
		Items = KRF.Schema.Map(KRF.Schema.String(32), KRF.Schema.U16, 40),
	}),
	events = {
		{
			id = "ItemAdded",
			payload = KRF.Schema.Struct({
				ItemId = KRF.Schema.String(32),
				Count = KRF.Schema.U16,
			}),
		},
	},
	audience = "Owner",
	--@example 4
}

return InventoryDomain
