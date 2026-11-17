--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local KRF = require(ReplicatedStorage.Packages.KRF)
local mergeDescendants = require(ReplicatedStorage.Shared.MergeDescendants)

local policies: KRF.ActionInputPolicies = mergeDescendants(script)

return policies
