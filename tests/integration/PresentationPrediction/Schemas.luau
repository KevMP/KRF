--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local Types = require(KRF.shared.ActionRequest.types)
local NetworkingTypes = require(KRF.shared.Networking.types)
local Schema: NetworkingTypes.Schema = require(KRF.shared.Networking.Schema)

local schemas: Types.ActionRequestSchemas = {
	Fireball = { start = Schema.Struct({ aim = Schema.F32 }) },
	Ward = {},
}

return schemas
