--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local packages: Folder = ReplicatedStorage:WaitForChild("Packages") :: Folder
packages:WaitForChild("KRF")
local KRF = ReplicatedStorage.Packages.KRF
local PublicTypes = require(KRF.client.Actor.types)
local Client = require(KRF.client)
local Registry: PublicTypes.ActorViewRegistry = require(KRF.client.Actor.ActorViewRegistry)
local NetworkingTypes = require(KRF.client.Networking.types)
local Commands: NetworkingTypes.CommandRuntime = require(KRF.client.Networking.CommandRuntime)
script.Parent:WaitForChild("Utils"):WaitForChild("ClientCorrelation")
local Correlation = require(script.Parent.Utils.ClientCorrelation)
local correlationGo: boolean = false
local control: RemoteEvent = ReplicatedStorage:WaitForChild("CommandTestControl") :: RemoteEvent
local view: PublicTypes.ActorView? = nil
local failed: boolean = false
local outcomes: { [number]: NetworkingTypes.CommandResult } = {}

Commands.OnCommandResult:Connect(function(result: NetworkingTypes.CommandResult): ()
	outcomes[result.requestId] = result
end)

local function report(phase: string, failure: string?, sentIds: { number }?): ()
	control:FireServer(phase, failure, sentIds)
end

local function waitFor(predicate: () -> boolean, reason: string): ()
	local deadline: number = os.clock() + 20

	while not predicate() do
		assert(os.clock() < deadline, reason)
		task.wait(0.02)
	end
end

control.OnClientEvent:Connect(function(phase: string, actorId: string?, otherId: string?, requester: boolean?): ()
	if failed then
		return
	end

	if phase == "Correlation" then
		correlationGo = true

		return
	end

	local reportPhase: string = phase
	local sentIds: { number }? = nil

	local completed: boolean, reason: any = pcall(function(): ()
		if phase == "Exercise" then
			assert(actorId ~= nil, "Expected native Actor identity")

			waitFor(function(): boolean
				local candidate: PublicTypes.ActorView? = Registry.GetActorViewById(actorId :: string)

				return candidate ~= nil and candidate:IsAvailable()
			end, "Normal client consumers did not install Actor views")

			view = Registry.GetActorViewById(actorId :: string)
			local first: number?, failure: string? = Commands.Send("Game.Ping")
			assert(first ~= nil and failure == nil and first > 0, "Expected raw request id after READY")
			local second: number? = nil
			second, failure = Commands.Send("Game.Interact", view, { choice = 7 })
			assert(second ~= nil and failure == nil and second > first, "Expected installed private target mapping")
			sentIds = { first, second }

			waitFor(function(): boolean
				return outcomes[first :: number] ~= nil and outcomes[second :: number] ~= nil
			end, "Native results were not delivered")

			assert(
				outcomes[first].status == "Accepted" and outcomes[first].commandId == "Game.Ping",
				"Expected correlated Ping acceptance"
			)

			assert(
				outcomes[second].status == "Accepted" and outcomes[second].targetActorView == view,
				"Expected N4-authorized exact Character target"
			)

			for _, event: any in { Commands.OnCommandResult, Commands.OnCommandUncertain } do
				assert(
					type(event.Connect) == "function"
						and type(event.Once) == "function"
						and type(event.Wait) == "function",
					"Expected KRF Event API"
				)

				for _, member: string in { "Fire", "Destroy", "DisconnectAll" } do
					local readable: boolean = pcall(function(): ()
						local _: any = event[member]
					end)

					assert(not readable, "KRF Event must reject owning-member access")
				end

				local writable: boolean = pcall(function(): ()
					event.Connect = function() end
				end)

				assert(not writable, "KRF Event must reject mutation")
			end

			local allowed: { [string]: boolean } = { Send = true, OnCommandResult = true, OnCommandUncertain = true }

			for key in next, Commands :: any do
				assert(allowed[key], "Public command facade leaked private ownership or transport")
			end
		elseif phase == "PrepareCorrelation" then
			assert(actorId ~= nil and otherId ~= nil, "Expected native correlation subjects")

			Correlation.Run(actorId, otherId, requester == true, function(): ()
				report("PrepareCorrelation")
			end, function(): boolean
				return correlationGo
			end)

			reportPhase = "Correlation"
		elseif phase == "Retire" then
			assert(view ~= nil, "Expected retained native view")

			waitFor(function(): boolean
				return not (view :: PublicTypes.ActorView):IsAvailable()
			end, "Native ActorRemove was not consumed")

			local requestId: number?, failure: string? = Commands.Send("Game.Interact", view, { choice = 7 })
			assert(requestId == nil and type(failure) == "string", "Retired ActorView must fail locally")
			Client._ResetForTests()
			Client._ResetForTests()
			requestId, failure = Commands.Send("Game.Ping")
			assert(requestId == nil and type(failure) == "string", "Shutdown must revoke command admission")
			assert(#Registry.GetAllActorViews() == 0, "Shutdown must clear Actor consumers")
		else
			error("Unexpected native command phase")
		end
	end)

	if not completed then
		failed = true
	end

	report(reportPhase, if completed then nil else tostring(reason), sentIds)
end)

local completed: boolean, reason: any = pcall(function(): ()
	assert(Commands ~= nil, "[N9 missing contract] client.Networking.CommandRuntime (#79.21)")
	local requestId: number?, failure: string? = Commands.Send("Game.Ping")
	assert(requestId == nil and type(failure) == "string", "Native Send before Init must fail locally")
	local initialized: boolean, startupFailure: Client.StartupFailure? = Client.Init()
	assert(initialized, if startupFailure ~= nil then startupFailure.reason else "Native Client.Init failed")
end)

failed = not completed
report("Startup", if completed then nil else tostring(reason))
