--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudioTestService = game:GetService("StudioTestService")
local Server = require(ReplicatedStorage.Packages.KRF.server)
local control: RemoteEvent = ReplicatedStorage:WaitForChild("InputTestControl") :: RemoteEvent

local finished: boolean = false
local reports: { [Player]: boolean } = {}
local count: number = 0

type Measurement = {
	iterations: number,
	matches: number,
	dispatchSeconds: number,
	customCalls: number?,
	customDispatchSeconds: number?,
	faultCalls: number?,
	faultDispatchSeconds: number?,
}

local measurements: { Measurement } = {}

local function finish(success: boolean, reason: string?): ()
	if finished then
		return
	end

	finished = true
	StudioTestService:EndTest({ success = success, reason = reason, clients = count, measurements = measurements })
end

control.OnServerEvent:Connect(function(player: Player, success: any, reason: any): ()
	if reports[player] or finished then
		return
	end

	if success ~= true then
		finish(false, tostring(reason))

		return
	end

	if
		type(reason) == "table"
		and reason.iterations == 16
		and reason.matches == 4096
		and type(reason.dispatchSeconds) == "number"
		and reason.dispatchSeconds >= 0
		and reason.dispatchSeconds < math.huge
	then
		table.insert(measurements, {
			iterations = reason.iterations,
			matches = reason.matches,
			dispatchSeconds = reason.dispatchSeconds,
			customCalls = if type(reason.customCalls) == "number" then reason.customCalls else nil,
			customDispatchSeconds = if type(reason.customDispatchSeconds) == "number"
				then reason.customDispatchSeconds
				else nil,
			faultCalls = if type(reason.faultCalls) == "number" then reason.faultCalls else nil,
			faultDispatchSeconds = if type(reason.faultDispatchSeconds) == "number"
				then reason.faultDispatchSeconds
				else nil,
		})
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
