--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local StudioTestService = game:GetService("StudioTestService")
local KRF = ReplicatedStorage.Packages.KRF
local ActorTypes = require(KRF.server.Actor.types)
local ResourceTypes = require(KRF.server.Resource.types)
local PropertyTypes = require(KRF.server.Property.types)
local ReplicationTypes = require(KRF.server.Replication.types)
local NetworkingTypes = require(KRF.server.Networking.types)
local SharedTypes = require(KRF.shared.Networking.types)
local Server = require(KRF.server)
local Actors: ActorTypes.ActorRuntime = require(KRF.server.Actor.ActorRuntime)
local Networking: NetworkingTypes.ServerNetworking = require(KRF.server.Networking.ServerNetworking)
local Awareness = require(KRF.server.Networking.ActorAwarenessRuntime)
local Transport = require(KRF.shared.Networking.Transport)
local control: RemoteEvent = ReplicatedStorage:WaitForChild("ResourcesViewTestControl") :: RemoteEvent

Players.CharacterAutoLoads = false

local originalAwareness = Awareness.new
local awareness: NetworkingTypes.ActorAwarenessRuntime? = nil
local actor: ActorTypes.Actor? = nil
local models: { Model } = {}
local ready: { [Player]: boolean } = {}
local reports: { [Player]: boolean } = {}
local completedPhases: { string } = {}
local phase: string = "Ready"
local finished: boolean = false

-- Observe the real factory. Normal Server.Init still installs every native dependency.
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

local function captureRemotes(): { [Instance]: boolean }
	local found: { [Instance]: boolean } = {}

	for _, instance: Instance in ReplicatedStorage:GetDescendants() do
		if instance:IsA("RemoteEvent") or instance:IsA("UnreliableRemoteEvent") or instance:IsA("RemoteFunction") then
			found[instance] = true
		end
	end

	return found
end

local function checkRemotes(before: { [Instance]: boolean }): ()
	local root: Instance? = ReplicatedStorage:FindFirstChild(Transport.ROOT_NAME)

	for instance: Instance in captureRemotes() do
		if not before[instance] then
			assert(
				root ~= nil
					and instance.Parent == root
					and (
						(instance.Name == Transport.RELIABLE_NAME and instance:IsA("RemoteEvent"))
						or (instance.Name == Transport.UNRELIABLE_NAME and instance:IsA("UnreliableRemoteEvent"))
					),
				"Resources created a separate framework Remote"
			)
		end
	end
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

local function resources(): ResourceTypes.InternalResourceController
	assert(actor ~= nil, "Expected native Actor")

	local controller: ResourceTypes.InternalResourceController? =
		actor:GetController("ResourceController") :: ResourceTypes.InternalResourceController?

	assert(controller ~= nil, "Normal startup did not install ResourceController")

	return controller
end

local function properties(): PropertyTypes.PropertyController
	assert(actor ~= nil, "Expected native Actor")

	local controller: PropertyTypes.PropertyController? =
		actor:GetController("PropertyController") :: PropertyTypes.PropertyController?

	assert(controller ~= nil, "Normal startup did not install PropertyController")

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
	model.Name = "NativeResourcesSubject"

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
		assert(publication ~= nil, "Expected normal N3 publication installation")

		assert(
			(resources():GetCurrent("Resource.Mana") :: number) > 20,
			"Quiet interval did not exercise automatic regeneration"
		)

		assert(
			publication:GetActorSequence(actor) == 0,
			"Pure automatic regeneration or private changes created N3 work"
		)

		resources():_beginMutationBatch()
		assert(resources():SetCurrent("Resource.Mana", 80))
		assert(resources():AddResource("Resource.Rage", 30))
		resources():_finishMutationBatch()
		resources():_dispatchChanges()
		assert(publication:GetActorSequence(actor) == 1, "Meaningful Resource batch must create one N3 commit")
		sendPhase("Live")
	elseif phase == "Live" then
		local publicChanges: number = 0

		local connection = resources().OnResourceChanged:Connect(function()
			publicChanges += 1
		end)

		assert(properties():SetBaseProperty("ManaRegen", 20))
		connection:Disconnect()
		assert(publicChanges == 0, "Rate-only Property change altered the public Resource event contract")
		sendPhase("Rate")
	elseif phase == "Rate" then
		assert(awareness ~= nil, "Expected native awareness installation")

		for player: Player in ready do
			local handle: number? = awareness:GetHandle(player, actor)
			assert(handle ~= nil, "Missing native recipient handle")

			local replaced: boolean, reason: string? =
				Networking.RequestReplacementBaseline(player, handle, "N7NativeTest")

			assert(replaced, reason)
		end

		sendPhase("Replacement")
	elseif phase == "Replacement" then
		assert(resources():SetCurrent("Resource.Mana", 35))
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
		error("Unexpected native Resources phase: " .. phase, 0)
	end
end

control.OnServerEvent:Connect(function(player: Player, payload: any)
	if finished then
		return
	end

	local completed: boolean, reason: any = pcall(function()
		local before: { [Instance]: boolean } = captureRemotes()
		assert(player.Parent == Players and typeof(payload) == "buffer", "Expected real native client report")
		local report: any = HttpService:JSONDecode(buffer.tostring(payload))
		assert(report.failure == nil, "Client " .. player.Name .. ": " .. tostring(report.failure))
		assert(report.phase == phase and not reports[player], "Unexpected or duplicate native phase report")

		if phase == "Ready" then
			assert(Networking.IsClientReady(player), "Client.Init returned without native readiness")
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
				registerActor()
				assert(resources():AddResource("Private.Live", 10))
				assert(resources():Spend("Private.Secret", 1))
				assert(properties():SetBaseProperty("PrivateRegen", 8))
				sendPhase("Initial")
			else
				advance()
			end
		end

		checkRemotes(before)
	end)

	if not completed then
		finish(false, tostring(reason))
	end
end)

task.delay(90, function()
	finish(false, "Native Resources fixture timeout in " .. phase)
end)

local before: { [Instance]: boolean } = captureRemotes()

local initialized: boolean, failure: Server.StartupFailure? = Server.Init({
	resources = {
		{
			id = "Resource.Mana",
			visibility = "ClientVisible",
			autoAssign = true,
			initialValue = 20,
			max = { value = 1000 },
			regen = { rate = { propertyName = "ManaRegen", defaultBaseValue = 10 } },
		},
		{
			id = "Resource.Stamina",
			visibility = "ClientVisible",
			autoAssign = true,
			initialValue = 20,
			max = { value = 1000 },
			regen = { rate = { value = 5 } },
		},
		{ id = "Resource.Rage", visibility = "ClientVisible", max = { value = 50 } },
		{
			id = "Private.Secret",
			visibility = "ServerOnly",
			autoAssign = true,
			max = { value = 100 },
			regen = { rate = { propertyName = "PrivateRegen", defaultBaseValue = 4 } },
		},
		{ id = "Private.Live", visibility = "ServerOnly", max = { value = 100 } },
	},
})

if not initialized then
	finish(false, if failure ~= nil then failure.reason else "Native Server.Init failed")
else
	local valid: boolean, reason: any = pcall(checkRemotes, before)

	if not valid then
		finish(false, tostring(reason))
	end
end
