--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudioTestService = game:GetService("StudioTestService")
local Server = require(ReplicatedStorage.Packages.KRF.server)
local control: RemoteEvent = ReplicatedStorage:WaitForChild("InputTestControl") :: RemoteEvent

local finished: boolean = false
local reports: { [Player]: boolean } = {}
local count: number = 0

local function finish(success: boolean, reason: string?): ()
	if finished then
		return
	end

	finished = true
	StudioTestService:EndTest({ success = success, reason = reason, clients = count })
end

control.OnServerEvent:Connect(function(player: Player, success: any, reason: any): ()
	if reports[player] or finished then
		return
	end

	if success ~= true then
		finish(false, tostring(reason))

		return
	end

	reports[player] = true
	count += 1

	if count == 2 then
		for _, descendant: Instance in game:GetDescendants() do
			if
				descendant:IsA("InputContext")
				and descendant.Parent ~= nil
				and descendant.Parent.Name == "KRFInputs"
			then
				finish(false, "ManagedInputReplicatedToServer")

				return
			end
		end

		finish(true, nil)
	end
end)

task.delay(45, function(): ()
	finish(false, "NativeInputTimeout")
end)

local success: boolean, failure = Server.Init({})

if not success then
	finish(false, if failure ~= nil then failure.reason else "ServerInitFailed")
end
