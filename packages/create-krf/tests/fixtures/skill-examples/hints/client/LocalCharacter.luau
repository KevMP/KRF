--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local KRF = require(ReplicatedStorage.Packages.KRF)

local LocalCharacter = {}

function LocalCharacter.Get(): KRF.ActorView?
	return nil
end

return LocalCharacter
