--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

if not game:IsLoaded() then
	game.Loaded:Wait()
end

local packages = ReplicatedStorage:WaitForChild("Packages")
local KRF = require(packages:WaitForChild("KRF"))
local ActionRequests = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ActionRequests"))
local ActionInputPolicies = require(script.Parent.ActionInputPolicies)
local Controls = require(script.Parent.Controls)
local EnergyDisplay = require(script.Parent.EnergyDisplay)

local started: boolean, failure: KRF.ClientStartupFailure? = KRF.Client.Init({
	actionRequestSchemas = ActionRequests,
	actionInputPolicies = ActionInputPolicies,
})

if not started then
	local detail: string = if failure then `{failure.system}: {failure.reason}` else "unknown failure"

	error(`KRF client startup failed ({detail})`, 0)
end

Controls.Start()
EnergyDisplay.Start()
