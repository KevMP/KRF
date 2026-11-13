--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage.Packages.KRF.shared.ActionRequest.types)

-- No client target/position claims: this small arena chooses its dummy on the server.
local schemas: Types.ActionRequestSchemas = {
	["Demo.FireBreath"] = {
		stop = {},
		allowInputInterrupt = true,
		requiresClientRelease = true,
		onDisconnect = "Interrupt",
	},
	["Demo.Fireball"] = {},
	["Demo.FlameStrike"] = {},
}

return schemas
