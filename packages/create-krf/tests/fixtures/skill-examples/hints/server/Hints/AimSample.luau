--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local KRF = require(ReplicatedStorage.Packages.KRF)
local Players = game:GetService("Players")

local AimSample: KRF.HintDefinition = {
	id = "AimSample",
	direction = "ClientToServer",
	target = "Actor",
	mode = "Latest",
	payload = KRF.Schema.Struct({
		Direction = KRF.Schema.Array(KRF.Schema.F32, 3),
	}),
	authorize = KRF.HintAuthorization.OwnerActor,
	--@example 3
}

return AimSample
