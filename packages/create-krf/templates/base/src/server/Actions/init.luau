--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local KRF = require(ReplicatedStorage.Packages.KRF)
local requireDescendants = require(script.Parent.RequireDescendants)

local actions: { KRF.ActionFactory } = requireDescendants(script)

return actions
