--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local control: RemoteEvent = ReplicatedStorage:WaitForChild("KRFStudioTest") :: RemoteEvent
local timeout: number = control:GetAttribute("Timeout") :: number
local alias: string = control:GetAttribute("Alias") :: string
local KRF = (require :: any)(ReplicatedStorage:WaitForChild("Packages"):WaitForChild(alias))
local localPlayer: Player = Players.LocalPlayer

control.OnClientEvent:Connect(function()
	local ok: boolean, failure: unknown = pcall(function()
		assert(RunService:IsClient(), "The client smoke script is not running on a client")
		local deadline: number = os.clock() + timeout

		while true do
			local character: Model? = localPlayer.Character
			if character ~= nil and KRF.ActorViewRegistry.GetActorViewByModel(character) ~= nil then
				return
			end

			if os.clock() > deadline then
				error("Timed out waiting for the local character's ActorView", 0)
			end

			task.wait(0.05)
		end
	end)

	control:FireServer(ok, if ok then nil else tostring(failure))
end)
