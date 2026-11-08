--!strict
-- One replicated network-only module required by both Server.Init and Client.Init.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local SharedTypes = require(KRF.shared.Networking.types)
local ActionRequestTypes = require(KRF.shared.ActionRequest.types)
local Schema: SharedTypes.Schema = require(KRF.shared.Networking.Schema)

local Aim: SharedTypes.SchemaDefinition = Schema.Struct({ x = Schema.F32, y = Schema.F32, z = Schema.F32 })

local schemas: ActionRequestTypes.ActionRequestSchemas = {
	["Combat.Fireball"] = { start = Schema.Struct({ aim = Aim }) },
	["Movement.Sprint"] = {
		stop = {},
		allowInputInterrupt = true,
		requiresClientRelease = true,
		onDisconnect = "Interrupt",
	},
	["Technique.Cast"] = {
		start = Schema.Struct({ techniqueId = Schema.String(64), aim = Aim }),
		stop = { parameters = Schema.Struct({ releaseAim = Aim }) },
		allowInputInterrupt = true,
		onDisconnect = "Interrupt",
	},
}

return schemas
