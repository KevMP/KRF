--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local KRF = require(ReplicatedStorage.Packages.KRF)
local ActionRequests = require(ReplicatedStorage.Shared.ActionRequests)
local Actions = require(script.Parent.Actions)
local PlayerActors = require(script.Parent.PlayerActors)
local Properties = require(script.Parent.Properties)
local Resources = require(script.Parent.Resources)
local Tags = require(script.Parent.Tags)

local started: boolean, failure: KRF.ServerStartupFailure? = KRF.Server.Init({
	properties = Properties,
	tags = Tags,
	resources = Resources,
	actions = Actions,
	actionRequestSchemas = ActionRequests,
})

if not started then
	local detail: string = if failure then `{failure.system}: {failure.reason}` else "unknown failure"

	error(`KRF server startup failed ({detail})`, 0)
end

PlayerActors.Start()
