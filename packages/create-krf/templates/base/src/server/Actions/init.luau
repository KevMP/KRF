--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local KRF = require(ReplicatedStorage.Packages.KRF)
local requireDescendants = require(ReplicatedStorage.Shared.RequireDescendants)

local actions: { KRF.ActionFactory } = requireDescendants(script)

return actions
