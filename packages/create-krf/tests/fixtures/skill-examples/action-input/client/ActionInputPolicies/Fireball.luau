--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local KRF = require(ReplicatedStorage.Packages.KRF)
local UserInputService = game:GetService("UserInputService")

local Fireball: KRF.ActionInputPolicies = {
	Fireball = {
		--@example 6
	},
}

return Fireball
