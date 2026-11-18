local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudioTestService = game:GetService("StudioTestService")

local control: Instance = ReplicatedStorage:WaitForChild("KRFStudioTest")
local clients: number = control:GetAttribute("Clients") :: number

local ran: boolean, result: any = pcall(function()
	return StudioTestService:ExecuteMultiplayerTestAsync(clients, {})
end)

local reported: any = if ran and type(result) == "table" then result else { success = false, reason = tostring(result) }
print("__KRF_STUDIO_RESULT__ " .. HttpService:JSONEncode(reported))

return nil
