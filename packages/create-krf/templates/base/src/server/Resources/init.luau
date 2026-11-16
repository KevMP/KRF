--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local KRF = require(ReplicatedStorage.Packages.KRF)
local requireDescendants = require(script.Parent.RequireDescendants)

local resources: { KRF.ResourceDefinition } = requireDescendants(script)

return resources
