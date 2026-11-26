--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local KRF = require(ReplicatedStorage.Packages.KRF)

local function showError(_reason: string): () end

local function setUpBuyButton(actorView: KRF.ActorView, buyButton: TextButton): (string) -> ()
	--@example 2

	return buy
end
