--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local Types = require(KRF.client.Networking.types)
local PublicTypes = require(KRF.client.Actor.types)
local SignalTypes = require(KRF.shared.Signal.types)
local Commands: Types.CommandRuntime = require(KRF.client.Networking.CommandRuntime)
local Hints: Types.HintRuntime = require(KRF.client.Networking.HintRuntime)
local Registry: PublicTypes.ActorViewRegistry = require(KRF.client.Actor.ActorViewRegistry)
local Scenario = {}

function Scenario.Run(ownId: string, otherId: string, requester: boolean, ready: () -> (), start: () -> boolean): ()
	local results: { [string]: Types.CommandResult } = {}
	local callbacks: number = 0
	local resultCount: number = 0
	local fault: string? = nil
	local connections: { SignalTypes.Connection } = {}
	local views: { PublicTypes.ActorView } = {}

	for _, id: string in { ownId, otherId } do
		local view: PublicTypes.ActorView? = Registry.GetActorViewById(id)
		assert(view ~= nil and view:IsAvailable(), "Expected both native ActorViews")
		table.insert(views, view)
	end

	local completed: boolean, reason: any = pcall(function()
		table.insert(
			connections,
			Commands.OnCommandResult:Connect(function(result: Types.CommandResult): ()
				resultCount += 1

				if result.status == "Accepted" then
					results[result.commandId] = result
				else
					if
						result.commandId ~= "Game.Pulse"
						or result.targetActorView ~= views[2]
						or result.reason ~= "ActorNotOwned"
					then
						fault = "Unexpected native rejection"
					end
				end
			end)
		)

		for index: number, view: PublicTypes.ActorView in views do
			local function observe(snapshot: PublicTypes.ActionSnapshot, terminal: boolean): ()
				local valid: boolean, failure: any = pcall(function()
					callbacks += 1

					if not requester then
						return
					end

					local commandId: string = if index == 2
						then "Game.Begin"
						elseif snapshot.actionId == "Native.Pulse" then "Game.Pulse"
						elseif snapshot.actionId == "Native.Interrupt" then "Game.Interrupt"
						elseif terminal then "Game.Follow"
						else "Game.Begin"

					local result: Types.CommandResult? = results[commandId]

					assert(
						result ~= nil,
						"Actual requester result callback must precede " .. commandId .. " Action callback"
					)

					if commandId ~= "Game.Follow" then
						local expected: number = if index == 2
							then result.result.pulseSequence
							else result.result.sequenceId

						assert(
							snapshot.sequenceId == expected,
							"Result sequence must equal replicated activation identity"
						)
					end
				end)

				if not valid then
					fault = tostring(failure)
				end
			end

			table.insert(
				connections,
				view:GetActions().OnActionStarted:Connect(function(snapshot: PublicTypes.ActionSnapshot): ()
					observe(snapshot, false)
				end)
			)

			table.insert(
				connections,
				view:GetActions().OnActionEnded:Connect(function(snapshot: PublicTypes.ActionSnapshot): ()
					observe(snapshot, true)
				end)
			)

			table.insert(
				connections,
				view:GetActions().OnActionInterrupted:Connect(function(snapshot: PublicTypes.ActionSnapshot): ()
					observe(snapshot, true)
				end)
			)
		end

		ready()
		local startDeadline: number = os.clock() + 20

		while not start() do
			assert(os.clock() < startDeadline, "Native correlation barrier timed out")
			task.wait()
		end

		if requester then
			for value = 1, 4 do
				assert(Hints.Send("Game.Look", views[1], value), "Expected competing native C2S Latest")
				assert(Hints.Send("Game.Pulse", nil, value), "Expected competing native C2S Pulse")
			end

			local first: number?, firstReason: string? = Commands.Send("Game.Begin", views[1])
			assert(first ~= nil and firstReason == nil, "Expected admitted generic Begin")
			local pulse: number?, pulseReason: string? = Commands.Send("Game.Pulse", views[1])
			assert(pulse ~= nil and pulseReason == nil, "Expected admitted generic Pulse")
			local interrupted: number?, interruptedReason: string? = Commands.Send("Game.Interrupt", views[1])
			assert(interrupted ~= nil and interruptedReason == nil, "Expected admitted generic interruption")

			local follow: number?, followReason: string? =
				Commands.Send("Game.Follow", views[1], { priorRequestId = first })

			assert(
				follow ~= nil and followReason == nil and follow > pulse,
				"Expected ordered follow-up before receiving Begin's result"
			)

			assert(
				Commands.Send("Game.Pulse", views[2]) ~= nil,
				"Awareness alone permits local targeting but not server authorization"
			)
		end

		local deadline: number = os.clock() + 20

		while callbacks < 8 or (requester and resultCount < 5) do
			assert(fault == nil, fault)
			assert(os.clock() < deadline, "Native correlation/lifecycle delivery timed out")
			task.wait()
		end

		assert(fault == nil, fault)
		assert(callbacks == 8, "Expected persistent activation, transient start/end, and start/interruption")
		assert(resultCount == (if requester then 5 else 0), "Only requester receives command results")
		local joinDeadline = os.clock() + 20

		while #Registry.GetAllActorViews() < 18 do
			assert(os.clock() < joinDeadline, "Multipart pressure Actors did not install")
			task.wait()
		end

		for _, candidate in Registry.GetAllActorViews() do
			assert(candidate:IsAvailable(), "A multipart baseline must install atomically")
			local padding = assert(candidate:GetDomain("Stress.Padding"))
			assert(padding:GetState() == string.rep("x", 8192), "Expected complete canonical padding")
		end

		for _, view: PublicTypes.ActorView in views do
			assert(#view:GetActions():GetActiveActions() == 0, "All native scenario activations must have ended")
		end
	end)

	for _, connection: SignalTypes.Connection in connections do
		connection:Disconnect()
	end

	if not completed then
		error(reason, 0)
	end
end

return Scenario
