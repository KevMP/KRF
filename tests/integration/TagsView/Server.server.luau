--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local StudioTestService = game:GetService("StudioTestService")
local KRF = ReplicatedStorage.Packages.KRF
local ActorTypes = require(KRF.server.Actor.types)
local TagTypes = require(KRF.server.Tags.types)
local ReplicationTypes = require(KRF.server.Replication.types)
local NetworkingTypes = require(KRF.server.Networking.types)
local SharedTypes = require(KRF.shared.Networking.types)
local Server = require(KRF.server)
local Actors: ActorTypes.ActorRuntime = require(KRF.server.Actor.ActorRuntime)
local Networking: NetworkingTypes.ServerNetworking = require(KRF.server.Networking.ServerNetworking)
local Awareness = require(KRF.server.Networking.ActorAwarenessRuntime)
local TagController = require(KRF.server.Tags.TagController)
local control: RemoteEvent = ReplicatedStorage:WaitForChild("TagsViewTestControl") :: RemoteEvent

Players.CharacterAutoLoads = false
local originalAwareness: typeof(Awareness.new) = Awareness.new
local awareness: NetworkingTypes.ActorAwarenessRuntime? = nil
local actor: ActorTypes.Actor? = nil
local models: { Model } = {}
local ready: { [Player]: boolean } = {}
local reports: { [Player]: boolean } = {}
local completedPhases: { string } = {}
local ticks: number = 0
local phase: string = "Ready"
local finished: boolean = false

-- Observe the real server factory without replacing its behavior or transport.
Awareness.new = function(
	publication: NetworkingTypes.PublicationRuntime,
	catalog: ReplicationTypes.PreparedReplicationDomainCatalog,
	protocol: SharedTypes.ClientProtocol,
	dependencies: NetworkingTypes.ActorAwarenessDependencies,
	options: NetworkingTypes.ActorAwarenessOptions
): NetworkingTypes.ActorAwarenessRuntime
	local created: NetworkingTypes.ActorAwarenessRuntime =
		originalAwareness(publication, catalog, protocol, dependencies, options)
	awareness = created
	return created
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
		ticks = ticks,
	})
end

local function tags(): TagTypes.InternalTagController
	assert(actor ~= nil, "Expected registered native Actor")
	local controller: TagTypes.InternalTagController? =
		actor:GetController("TagController") :: TagTypes.InternalTagController?
	assert(controller ~= nil, "Native startup did not automatically install TagController")
	return controller
end

local function sendPhase(nextPhase: string): ()
	assert(actor ~= nil, "Expected native Actor identity")
	phase = nextPhase
	reports = {}
	for player: Player in ready do
		control:FireClient(
			player,
			buffer.fromstring(HttpService:JSONEncode({ phase = phase, actorId = actor:GetId() }))
		)
	end
end

local function registerActor(): ()
	local model: Model = Instance.new("Model")
	model.Name = "NativeTagsSubject"
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
end

local function advance(): ()
	assert(actor ~= nil, "Expected native Actor")
	if phase == "Initial" then
		local publication: NetworkingTypes.PublicationRuntime? = Networking._GetPublicationRuntimeForTests()
		assert(publication ~= nil, "Expected ordinary N3 publication runtime")
		assert(publication:GetActorSequence(actor) == 0, "Countdown or ticks created N3 publication work")
		assert(ticks > 0, "Native quiet interval did not exercise real Tag ticks")
		local controller: TagTypes.InternalTagController = tags()
		controller:_beginMutationBatch()
		assert(controller:AddTag("Buff.NativeStack", { duration = 50 }))
		assert(controller:AddTag("Private.Native"))
		assert(controller:AddTag("Status.NativeTimed", { duration = 90 }))
		assert(controller:RemoveSingleTag("Buff.NativeStack"))
		controller:_dispatchMutationEvents(controller:_finishMutationBatch())
		sendPhase("LiveBatch")
	elseif phase == "LiveBatch" then
		assert(awareness ~= nil, "Expected normal native awareness installation")
		for player: Player in ready do
			local handle: number? = awareness:GetHandle(player, actor)
			assert(handle ~= nil, "Expected native recipient handle")
			local replaced: boolean, reason: string? =
				Networking.RequestReplacementBaseline(player, handle, "N6NativeTest")
			assert(replaced, reason)
		end
		sendPhase("Replacement")
	elseif phase == "Replacement" then
		assert(tags():RemoveTag("Buff.NativeStack"))
		sendPhase("ManualRemoval")
	elseif phase == "ManualRemoval" then
		-- Force real authoritative expiry without waiting ninety wall-clock seconds.
		TagController.Step(1000)
		sendPhase("Expiry")
	elseif phase == "Expiry" then
		local removed: boolean, reason: string? = Actors.UnregisterActor(actor)
		assert(removed, reason)
		sendPhase("ActorRemoval")
	elseif phase == "ActorRemoval" then
		registerActor()
		sendPhase("Respawn")
	elseif phase == "Respawn" then
		sendPhase("Reset")
	elseif phase == "Reset" then
		finish(true, nil)
	else
		error("Unexpected native N6 phase: " .. phase, 0)
	end
end

control.OnServerEvent:Connect(function(player: Player, payload: any)
	if finished then
		return
	end
	local completed: boolean, reason: any = pcall(function()
		assert(player.Parent == Players and typeof(payload) == "buffer", "Expected a real native client report")
		local report: any = HttpService:JSONDecode(buffer.tostring(payload))
		assert(report.failure == nil, "Client " .. player.Name .. ": " .. tostring(report.failure))
		assert(report.phase == phase, "Client reported an unexpected native phase")
		assert(not reports[player], "Duplicate native client report")
		if phase == "Ready" then
			assert(Networking.IsClientReady(player), "Native Client.Init returned before readiness")
			ready[player] = true
		else
			assert(ready[player], "Unknown native client")
		end
		reports[player] = true
		local count: number = 0
		for _ in reports do
			count += 1
		end
		if count == 2 then
			table.insert(completedPhases, phase)
			if phase == "Ready" then
				assert(#Players:GetPlayers() == 2, "Expected two native clients")
				registerActor()
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
	finish(false, "Native N6 fixture timeout in " .. phase)
end)
local initialized: boolean, failure: Server.StartupFailure? = Server.Init({
	tags = {
		{ id = "Buff.NativeStack", visibility = "ClientVisible", duplicateBehavior = "Stack", maxStacks = 3 },
		{
			id = "Status.NativeTimed",
			visibility = "ClientVisible",
			duplicateBehavior = "Refresh",
			defaultDuration = 60,
			tickInterval = 0.1,
			onTick = function()
				ticks += 1
			end,
		},
		{
			id = "Private.Native",
			visibility = "ServerOnly",
			duplicateBehavior = "Refresh",
			defaultDuration = 60,
			tickInterval = 0.1,
			onTick = function()
				ticks += 1
			end,
			properties = { WalkSpeed = { multiply = 2 } },
		},
	},
	controllers = {
		{
			key = "Game.SeedTags",
			dependsOn = { "TagController" },
			factory = function(subject: ActorTypes.Actor): ActorTypes.Controller
				local controller: TagTypes.TagController? =
					subject:GetController("TagController") :: TagTypes.TagController?
				assert(controller ~= nil, "Expected TagController before game setup")
				assert(controller:AddTag("Status.NativeTimed"))
				assert(controller:AddTag("Buff.NativeStack", { duration = 20 }))
				assert(controller:AddTag("Buff.NativeStack", { duration = 40 }))
				assert(controller:AddTag("Private.Native"))
				return { Destroy = function() end }
			end,
		},
	},
})
if not initialized then
	finish(false, if failure ~= nil then failure.reason else "Native Server.Init failed")
end
