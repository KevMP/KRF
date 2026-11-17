--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local KRF = require(ReplicatedStorage.Packages.KRF)

local Focus: KRF.ActionInputPolicies = {
	Focus = { activation = "WhileDown" },
}

return Focus
