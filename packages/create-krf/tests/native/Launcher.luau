--!strict
local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local StudioTestService = game:GetService("StudioTestService")

assert(RunService:IsEdit(), "The starter launcher requires the Edit DataModel")

local control: RemoteEvent = ReplicatedStorage:WaitForChild("StarterTestControl") :: RemoteEvent
local scenario: string = control:GetAttribute("Scenario") :: string
local result: any = StudioTestService:ExecuteMultiplayerTestAsync(2, scenario)
local encoded: string = HttpService:JSONEncode(result)

if type(result) == "table" and result.success == true then
	print("__KRF_STARTER_PASS__ " .. encoded)
else
	print("__KRF_STARTER_FAIL__ " .. encoded)
	error("Native starter test failed: " .. encoded, 0)
end

return nil
