--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local KRF = require(ReplicatedStorage.Packages.KRF)

local policies: KRF.ActionInputPolicies = {
	Focus = { activation = "WhileDown" },
}

return policies
