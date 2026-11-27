--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local KRF = require(ReplicatedStorage.Packages.KRF)
local ActionPredictionPolicies = require(script.Parent.ActionPredictionPolicies)

local ActionRequests: KRF.ActionRequestSchemas = { Fireball = {} }
local ActionInputPolicies: KRF.ActionInputPolicies = {}
local Presentations: { KRF.PresentationDefinition } = {}

--@example 5

print(started, failure)
