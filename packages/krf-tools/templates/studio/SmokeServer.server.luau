--!strict
local LogService = game:GetService("LogService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local StudioTestService = game:GetService("StudioTestService")

local control: RemoteEvent = ReplicatedStorage:WaitForChild("KRFStudioTest") :: RemoteEvent
local clients: number = control:GetAttribute("Clients") :: number
local timeout: number = control:GetAttribute("Timeout") :: number
local alias: string = control:GetAttribute("Alias") :: string
local KRF = (require :: any)(ReplicatedStorage:WaitForChild("Packages"):WaitForChild(alias))

local phase: string = "Players"
local completed: { string } = {}
local reports: { [Player]: { ok: boolean, detail: string } } = {}
local serverErrors: { string } = {}

for _, entry in LogService:GetLogHistory() do
	if entry.messageType == Enum.MessageType.MessageError then
		table.insert(serverErrors, entry.message)
	end
end

LogService.MessageOut:Connect(function(message: string, messageType: Enum.MessageType)
	if messageType == Enum.MessageType.MessageError then
		table.insert(serverErrors, message)
	end
end)

control.OnServerEvent:Connect(function(player: Player, ok: unknown, detail: unknown)
	reports[player] = { ok = ok == true, detail = tostring(detail) }
end)

local function waitFor(description: string, predicate: () -> boolean): ()
	local deadline: number = os.clock() + timeout

	while not predicate() do
		if os.clock() > deadline then
			error(`Timed out waiting for {description}`, 0)
		end

		task.wait(0.05)
	end
end

local function step(name: string, body: () -> ()): ()
	phase = name
	body()
	table.insert(completed, name)
end

local function characterActor(player: Player): any
	local character: Model? = player.Character
	return if character ~= nil then KRF.ActorRegistry.GetActorByModel(character) else nil
end

local ok: boolean, failure: unknown = pcall(function()
	assert(RunService:IsServer(), "The server smoke script is not running on the server")

	step("Players", function()
		waitFor(`{clients} players to join`, function()
			return #Players:GetPlayers() >= clients
		end)
	end)

	step("Actors", function()
		waitFor("every player character to be registered as an Actor", function()
			for _, player: Player in Players:GetPlayers() do
				if characterActor(player) == nil then
					return false
				end
			end

			return true
		end)
	end)

	step("ActorViews", function()
		for _, player: Player in Players:GetPlayers() do
			control:FireClient(player)
		end

		waitFor("every client to report its own ActorView", function()
			for _, player: Player in Players:GetPlayers() do
				if reports[player] == nil then
					return false
				end
			end

			return true
		end)

		for player: Player, report in reports do
			if not report.ok then
				error(`{player.Name}: {report.detail}`, 0)
			end
		end
	end)
end)

StudioTestService:EndTest({
	success = ok,
	reason = if ok then nil else tostring(failure),
	serverError = if ok then nil else serverErrors[1],
	phase = phase,
	completed = completed,
	players = #Players:GetPlayers(),
})
