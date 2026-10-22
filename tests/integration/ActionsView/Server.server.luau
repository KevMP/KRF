--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local StudioTestService = game:GetService("StudioTestService")
local KRF = ReplicatedStorage.Packages.KRF
local ActionTypes = require(KRF.server.Action.types)
local ActorTypes = require(KRF.server.Actor.types)
local ReplicationTypes = require(KRF.server.Replication.types)
local NetworkingTypes = require(KRF.server.Networking.types)
local SharedTypes = require(KRF.shared.Networking.types)
local Server = require(KRF.server)
local Actors: ActorTypes.ActorRuntime = require(KRF.server.Actor.ActorRuntime)
local Networking: NetworkingTypes.ServerNetworking = require(KRF.server.Networking.ServerNetworking)
local Awareness = require(KRF.server.Networking.ActorAwarenessRuntime)
local control: RemoteEvent = ReplicatedStorage:WaitForChild("ActionsViewTestControl") :: RemoteEvent

Players.CharacterAutoLoads = false

local originalAwareness = Awareness.new
local awareness: NetworkingTypes.ActorAwarenessRuntime? = nil
local actor: ActorTypes.Actor? = nil
local models: { Model } = {}
local reports: { [Player]: boolean } = {}
local ready: { [Player]: boolean } = {}
local phase: string = "Ready"
local completedPhases: { string } = {}
local finished: boolean = false

Awareness.new = function(
	publication: NetworkingTypes.PublicationRuntime,
	catalog: ReplicationTypes.PreparedReplicationDomainCatalog,
	protocol: SharedTypes.ClientProtocol,
	dependencies: NetworkingTypes.ActorAwarenessDependencies,
	options: NetworkingTypes.ActorAwarenessOptions
): NetworkingTypes.ActorAwarenessRuntime
	local runtime: NetworkingTypes.ActorAwarenessRuntime =
		originalAwareness(publication, catalog, protocol, dependencies, options)

	awareness = runtime

	return runtime
end

local function finish(success: boolean, reason: string?): ()
	if finished then
		return
	end

	finished = true

	local cleaned: boolean, cleanupReason: any = pcall(function()
		if actor ~= nil then
			Actors.UnregisterActor(actor)
		end

		Networking.Destroy()

		for _, model: Model in models do
			model:Destroy()
		end
	end)

	Awareness.new = originalAwareness

	StudioTestService:EndTest({
		success = success and cleaned,
		reason = reason or (if cleaned then nil else tostring(cleanupReason)),
		phase = phase,
		completedPhases = completedPhases,
	})
end

local function actions(): ActionTypes.ActionController
	assert(actor ~= nil, "Expected native Actor")

	local controller: ActionTypes.ActionController? =
		actor:GetController("ActionController") :: ActionTypes.ActionController?

	assert(controller ~= nil, "Normal startup must auto-attach ActionController")

	return controller
end

local function start(id: string): number
	local result: ActionTypes.ActionRequestResult =
		actions():RequestAction(id, { secret = "Private.Parameters", callback = function() end })

	assert(result.accepted, "Native setup Action was rejected")

	return result.sequenceId
end

local function registerActor(): ()
	local model: Model = Instance.new("Model")
	model.Name = "NativeActionsSubject"

	local root: Part = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Anchored = true
	root.Parent = model
	model.PrimaryPart = root
	model.Parent = workspace
	table.insert(models, model)
	local registered: ActorTypes.Actor?, reason: string? = Actors.RegisterActor(model)
	assert(registered ~= nil, reason)
	actor = registered
	assert(start("Action.A") == 1, "First native sequence must be one")
	assert(start("Private.Secret") == 2, "Private Actions must share sequence namespace")
	assert(start("Action.A") == 3, "Duplicate Action must get a distinct sequence")
end

local function sendPhase(nextPhase: string): ()
	assert(actor ~= nil, "Expected Actor identity")
	phase = nextPhase
	reports = {}

	for player: Player in ready do
		control:FireClient(
			player,
			buffer.fromstring(HttpService:JSONEncode({ phase = phase, actorId = actor:GetId() }))
		)
	end
end

local function advance(): ()
	assert(actor ~= nil, "Expected native Actor")

	if phase == "Initial" then
		assert(actions():EndAction(1))
		assert(start("Action.Cast") == 4, "Native Cast sequence differs")
		assert(start("Action.PulseEnd") == 5, "Native End pulse sequence differs")
		assert(start("Action.PulseInterrupt") == 6, "Native Interrupt pulse sequence differs")
		sendPhase("Live")
	elseif phase == "Live" then
		assert(actions():EndAction(4))
		assert(actions():InterruptAction(3, "Private.InterruptionReason"))
		sendPhase("Terminal")
	elseif phase == "Terminal" then
		assert(awareness ~= nil, "Normal startup must install awareness")

		for player: Player in ready do
			local handle: number? = awareness:GetHandle(player, actor)
			assert(handle ~= nil, "Expected actual recipient handle")

			local replaced: boolean, reason: string? =
				Networking.RequestReplacementBaseline(player, handle, "N8NativeTest")

			assert(replaced, reason)
		end

		sendPhase("Replacement")
	elseif phase == "Replacement" then
		assert(start("Action.A") == 7, "Recovery reused a terminal sequence")
		sendPhase("AfterRecovery")
	elseif phase == "AfterRecovery" then
		assert(Actors.UnregisterActor(actor))
		sendPhase("Removed")
	elseif phase == "Removed" then
		registerActor()
		sendPhase("Respawn")
	elseif phase == "Respawn" then
		sendPhase("Reset")
	elseif phase == "Reset" then
		finish(true, nil)
	else
		error("Unexpected native Actions phase: " .. phase, 0)
	end
end

control.OnServerEvent:Connect(function(player: Player, payload: any)
	if finished then
		return
	end

	local completed: boolean, reason: any = pcall(function()
		assert(player.Parent == Players and typeof(payload) == "buffer", "Expected actual native client report")
		local report: any = HttpService:JSONDecode(buffer.tostring(payload))
		assert(report.failure == nil, "Client " .. player.Name .. ": " .. tostring(report.failure))
		assert(report.phase == phase and not reports[player], "Unexpected or duplicate native phase report")

		if phase == "Ready" then
			assert(Networking.IsClientReady(player), "Client.Init did not finish native handshake")
			ready[player] = true
		end

		reports[player] = true

		local count: number = 0

		for _ in reports do
			count += 1
		end

		if count == 2 then
			table.insert(completedPhases, phase)

			if phase == "Ready" then
				sendPhase("Initial")
			else
				advance()
			end
		end
	end)

	if not completed then
		finish(false, tostring(reason))
	end
end)

task.delay(90, function()
	finish(false, "Native Actions timeout in " .. phase)
end)

local initialized: boolean, failure: Server.StartupFailure? = Server.Init({
	resources = {
		{ id = "Mana", visibility = "ClientVisible", autoAssign = true, initialValue = 100, max = { value = 100 } },
	},
	tags = { { id = "Casting", visibility = "ClientVisible", duplicateBehavior = "Ignore" } },
	actions = {
		function(): ActionTypes.ActionDefinition
			return { id = "Action.A", visibility = "ClientVisible", autoGrant = true }
		end,
		function(): ActionTypes.ActionDefinition
			return { id = "Private.Secret", visibility = "ServerOnly", autoGrant = true, locks = { "Private.Lock" } }
		end,
		function(): ActionTypes.ActionDefinition
			return {
				id = "Action.Cast",
				visibility = "ClientVisible",
				autoGrant = true,
				costs = { Mana = 20 },
				activeTags = { "Casting" },
			}
		end,
		function(): ActionTypes.ActionDefinition
			return {
				id = "Action.PulseEnd",
				visibility = "ClientVisible",
				autoGrant = true,
				onStart = function(context: ActionTypes.ActionExecutionContext)
					context:End()
				end,
			}
		end,
		function(): ActionTypes.ActionDefinition
			return {
				id = "Action.PulseInterrupt",
				visibility = "ClientVisible",
				autoGrant = true,
				onStart = function(context: ActionTypes.ActionExecutionContext)
					context:Interrupt("Private.Reason")
				end,
			}
		end,
	},
})

if not initialized then
	finish(false, if failure ~= nil then failure.reason else "Native Server.Init failed")
else
	local registered: boolean, reason: any = pcall(registerActor)

	if not registered then
		finish(false, tostring(reason))
	end
end
