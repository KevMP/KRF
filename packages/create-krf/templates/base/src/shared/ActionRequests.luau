--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local KRF = require(ReplicatedStorage.Packages.KRF)

local requests: KRF.ActionRequestSchemas = {
	Focus = {
		stop = {},
		allowInputInterrupt = true,
		requiresClientRelease = true,
		onDisconnect = "Interrupt",
	},
}

return requests
