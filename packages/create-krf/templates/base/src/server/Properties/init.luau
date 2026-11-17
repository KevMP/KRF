--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local KRF = require(ReplicatedStorage.Packages.KRF)
local requireDescendants = require(ReplicatedStorage.Shared.RequireDescendants)

local properties: { KRF.PropertyDefinition } = requireDescendants(script)

return properties
