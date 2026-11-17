--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local KRF = require(ReplicatedStorage.Packages.KRF)
local mergeDescendants = require(script.Parent.MergeDescendants)

local requests: KRF.ActionRequestSchemas = mergeDescendants(script)

return requests
