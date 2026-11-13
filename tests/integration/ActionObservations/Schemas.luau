--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local Types = require(KRF.shared.ActionRequest.types)
local input: Types.ActionRequestSchemas = require(ReplicatedStorage.ActionInputSchemas)

local schemas: Types.ActionRequestSchemas = {
	["Combat.Rasengan"] = input["Combat.Rasengan"],
	["Combat.Fireball"] = input["Combat.Fireball"],
	["Movement.Sprint"] = input["Movement.Sprint"],
	["Mode.Aura"] = input["Mode.Aura"],
}

return schemas
