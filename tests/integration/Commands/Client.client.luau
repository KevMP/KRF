--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local packages: Folder = ReplicatedStorage:WaitForChild("Packages") :: Folder
packages:WaitForChild("KRF")
local KRF = ReplicatedStorage.Packages.KRF
local PublicTypes = require(KRF.client.Actor.types)
local Client = require(KRF.client)
local Registry: PublicTypes.ActorViewRegistry = require(KRF.client.Actor.ActorViewRegistry)
local commandModule: Instance? = KRF.client.Networking:FindFirstChild("CommandRuntime")
local requireOptional: (ModuleScript) -> any = require :: any
local Commands: any = if commandModule ~= nil then requireOptional(commandModule :: ModuleScript) else nil
local control: RemoteEvent = ReplicatedStorage:WaitForChild("CommandTestControl") :: RemoteEvent
local view: PublicTypes.ActorView? = nil
local failed: boolean = false

local function report(phase: string, failure: string?): ()
	control:FireServer(phase, failure)
end

local function waitFor(predicate: () -> boolean, reason: string): ()
	local deadline: number = os.clock() + 20

	while not predicate() do
		assert(os.clock() < deadline, reason)
		task.wait(0.02)
	end
end

control.OnClientEvent:Connect(function(phase: string, actorId: string?): ()
	if failed then
		return
	end

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

			assert(
				Commands.OnCommandResult.Fire == nil and Commands.OnCommandUncertain.Fire == nil,
				"Public events must not expose owning Signals"
			)

			local allowed: { [string]: boolean } = { Send = true, OnCommandResult = true, OnCommandUncertain = true }

			for key in Commands do
				assert(allowed[key], "Public command facade leaked private ownership or transport")
			end
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

	report(phase, if completed then nil else tostring(reason))
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
