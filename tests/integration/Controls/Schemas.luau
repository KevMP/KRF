--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage.Packages.KRF.shared.ActionRequest.types)
local shared: Types.ActionRequestSchemas = require(ReplicatedStorage.ActionInputSchemas)

local schemas: Types.ActionRequestSchemas = {
	["Combat.Rasengan"] = shared["Combat.Rasengan"],
	["Combat.Fireball"] = shared["Combat.Fireball"],
}

return schemas
