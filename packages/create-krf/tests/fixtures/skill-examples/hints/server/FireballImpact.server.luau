--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local KRF = require(ReplicatedStorage.Packages.KRF)
local Players = game:GetService("Players")

local function sendImpact(ctx: KRF.ActionExecutionContext, target: KRF.Actor): ()
	--@example 3
end

return sendImpact
