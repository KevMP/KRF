--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local Types = require(KRF.shared.ActionRequest.types)
local NetworkingTypes = require(KRF.shared.Networking.types)
local Schema: NetworkingTypes.Schema = require(KRF.shared.Networking.Schema)

local schemas: Types.ActionRequestSchemas = {
	["Combat.Rasengan"] = {
		start = Schema.Struct({ aim = Schema.F32 }),
		stop = { parameters = Schema.Struct({ releaseAim = Schema.F32 }) },
		allowInputInterrupt = true,
		requiresClientRelease = true,
		onDisconnect = "Interrupt",
	},
	["Combat.Fireball"] = { start = Schema.Struct({ aim = Schema.F32 }) },
	["Combat.OneShot"] = { stop = {}, allowInputInterrupt = true },
	["Combat.Keep"] = { stop = {}, allowInputInterrupt = true },
	["Movement.Sprint"] = { stop = {}, allowInputInterrupt = true, onDisconnect = "Interrupt" },
	["Mode.Aura"] = { stop = {}, allowInputInterrupt = true },
}

return schemas
