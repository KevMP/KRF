--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudioTestService = game:GetService("StudioTestService")
local KRF = ReplicatedStorage.Packages.KRF
local ActorTypes = require(KRF.server.Actor.types)
local ActionTypes = require(KRF.server.Action.types)
local Server = require(KRF.server)
local Actors: ActorTypes.ActorRuntime = require(KRF.server.Actor.ActorRuntime)
local Networking = require(KRF.server.Networking.ServerNetworking)
local schemas = require(ReplicatedStorage.ObservationSchemas)
local report: RemoteEvent = ReplicatedStorage:WaitForChild("ObservationReport") :: RemoteEvent
local probe: RemoteFunction = ReplicatedStorage:WaitForChild("ObservationProbe") :: RemoteFunction
local owners: { [ActorTypes.Actor]: Player } = {}
local actors: { ActorTypes.Actor } = {}
local models: { Model } = {}
local reported: { [Player]: boolean } = {}
local releaseAims: { [Player]: number } = {}
local finished: boolean = false
local npc: ActorTypes.Actor

Players.CharacterAutoLoads = false

local function finish(success: boolean, reason: string?): ()
	if finished then
		return
	end

	finished = true

	for _, actor: ActorTypes.Actor in actors do
		Actors.UnregisterActor(actor)
	end

	Networking.Destroy()

	for _, model: Model in models do
		model:Destroy()
	end

	StudioTestService:EndTest({ success = success, reason = reason })
end

local function factory(definition: ActionTypes.ActionDefinition): ActionTypes.ActionFactory
	return function(): ActionTypes.ActionDefinition
		return table.clone(definition)
	end
end

local initialized: boolean, failure = Server.Init({
	actions = {
		factory({
			id = "Combat.Rasengan",
			visibility = "ServerOnly",
			autoGrant = true,
			onStopRequested = function(context, request): ()
				releaseAims[owners[context.actor]] = request.parameters.releaseAim
			end,
		}),
		factory({
			id = "Combat.Fireball",
			visibility = "ClientVisible",
			autoGrant = true,
			onStart = function(context): ()
				context:End()
			end,
		}),
		factory({ id = "Movement.Sprint", visibility = "ClientVisible", autoGrant = true }),
		factory({ id = "Mode.Aura", visibility = "ClientVisible", autoGrant = true }),
	},
	actionRequestSchemas = schemas,
	actionControlAuthority = function(player: Player, actor: ActorTypes.Actor): boolean
		return owners[actor] == player
	end,
})

assert(initialized, if failure ~= nil then failure.reason else "ServerInitFailed")

local function spawn(name: string): ActorTypes.Actor
	local model: Model = Instance.new("Model")
	model.Name = name

	local root: Part = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Anchored = true
	root.CFrame = CFrame.new(#models * 6, 0, 0)
	root.Parent = model
	model.PrimaryPart = root
	model.Parent = workspace
	table.insert(models, model)
	local actor: ActorTypes.Actor = assert(Actors.RegisterActor(model))
	table.insert(actors, actor)

	return actor
end

npc = spawn("ObservationNPC")
ReplicatedStorage:SetAttribute("ObservationNPCId", npc:GetId())

local function admit(player: Player): ()
	local actor: ActorTypes.Actor = spawn(player.Name .. ".A")
	local other: ActorTypes.Actor = spawn(player.Name .. ".B")

	owners[actor], owners[other] = player, player
	player.Character = actor.model
	player:SetAttribute("ObservationActorA", actor:GetId())
	player:SetAttribute("ObservationActorB", other:GetId())
end

probe.OnServerInvoke = function(player: Player, operation: unknown): { [string]: number }
	if operation == "NPC" then
		local controller: ActionTypes.ActionController =
			assert(npc:GetController("ActionController")) :: ActionTypes.ActionController

		local result: ActionTypes.ActionRequestResult = controller:RequestAction("Movement.Sprint")
		assert(result.accepted and result.sequenceId ~= nil, "NPCStartFailed")

		return { npcSequenceId = result.sequenceId }
	end

	return { releaseAim = releaseAims[player] or -1 }
end

report.OnServerEvent:Connect(function(player: Player, failureReason: unknown): ()
	if finished or reported[player] then
		return
	end

	if failureReason ~= nil then
		finish(false, "ObservationClientFailure:" .. tostring(failureReason))

		return
	end

	if releaseAims[player] ~= 8 then
		finish(false, "OriginalReleaseAimLost")

		return
	end

	reported[player] = true

	local count: number = 0

	for _ in reported do
		count += 1
	end

	if count == 2 then
		finish(true)
	end
end)

for _, player: Player in Players:GetPlayers() do
	admit(player)
end

Players.PlayerAdded:Connect(admit)

task.delay(60, function(): ()
	finish(false, "NativeObservationTimeout")
end)
