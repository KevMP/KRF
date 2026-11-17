--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local KRF = require(ReplicatedStorage.Packages.KRF)
local requireDescendants = require(script.Parent.RequireDescendants)

local tags: { KRF.TagDefinition } = requireDescendants(script)

return tags
