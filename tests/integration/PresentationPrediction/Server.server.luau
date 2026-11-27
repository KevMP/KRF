--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudioTestService = game:GetService("StudioTestService")
local KRF = ReplicatedStorage.Packages.KRF
local Server = require(KRF.server)
local ActorRuntime = require(KRF.server.Actor.ActorRuntime)
local ActorTypes = require(KRF.server.Actor.types)
local ActionTypes = require(KRF.server.Action.types)
local TagTypes = require(KRF.server.Tags.types)
local Networking = require(KRF.server.Networking.ServerNetworking)
local FireballRequirements = require(ReplicatedStorage.PredictionShared.FireballRequirements)
local schemas = require(ReplicatedStorage.PredictionShared.Schemas)
local report: RemoteEvent = ReplicatedStorage:WaitForChild("PredictionReport") :: RemoteEvent
local probe: RemoteFunction = ReplicatedStorage:WaitForChild("PredictionProbe") :: RemoteFunction

local FIREBALL_SECONDS: number = 0.15
local owners: { [ActorTypes.Actor]: Player } = {}
local actorsByPlayer: { [Player]: ActorTypes.Actor } = {}
local models: { Model } = {}
local results: { [string]: any } = {}
local reported: number = 0
local finished: boolean = false

Players.CharacterAutoLoads = false

local function finish(success: boolean, reason: string?): ()
	if finished then
		return
	end

	finished = true
	Networking.Destroy()

	for _, model: Model in models do
		model:Destroy()
	end

	StudioTestService:EndTest({ success = success, reason = reason, results = results })
end

local initialized: boolean, failure = Server.Init({
	tags = {
		{ id = "Status.Grounded", duplicateBehavior = "Ignore", visibility = "ClientVisible" },
		{ id = "Status.Stunned", duplicateBehavior = "Ignore", visibility = "ClientVisible" },
	},
	resources = {
		{
			id = "Mana",
			max = { value = 100000 },
			initialValue = 100000,
			visibility = "ClientVisible",
			autoAssign = true,
		},
	},
	actions = {
		function(): ActionTypes.ActionDefinition
			return {
				id = "Fireball",
				visibility = "ClientVisible",
				autoGrant = true,
				requiredTags = FireballRequirements.requiredTags,
				blockedTags = FireballRequirements.blockedTags,
				resourceRequirements = FireballRequirements.resourceRequirements,
				costs = FireballRequirements.costs,
				onStart = function(context: ActionTypes.ActionExecutionContext): ()
					task.delay(FIREBALL_SECONDS, function(): ()
						if context:IsActive() then
							context:End()
						end
					end)
				end,
			}
		end,
		function(): ActionTypes.ActionDefinition
			return {
				id = "Ward",
				visibility = "ClientVisible",
				autoGrant = true,
				onCanStart = function(): (boolean, string?)
					return false, "WardSealed"
				end,
			}
		end,
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

	local actor: ActorTypes.Actor = assert(ActorRuntime.RegisterActor(model))
	local tags: TagTypes.TagController = actor:GetController("TagController") :: TagTypes.TagController
	assert(tags:AddTag("Status.Grounded"), "Expected grounded actor")

	return actor
end

local npc: ActorTypes.Actor = spawn("PredictionNPC")
ReplicatedStorage:SetAttribute("PredictionNPCId", npc:GetId())

local function admit(player: Player): ()
	local actor: ActorTypes.Actor = spawn(player.Name .. ".Caster")

	owners[actor] = player
	actorsByPlayer[player] = actor
	player.Character = actor.model
	player:SetAttribute("PredictionActor", actor:GetId())
end

probe.OnServerInvoke = function(player: Player, operation: unknown): boolean
	local actor: ActorTypes.Actor = assert(actorsByPlayer[player], "UnknownPredictionPlayer")
	local tags: TagTypes.TagController = actor:GetController("TagController") :: TagTypes.TagController

	if operation == "Stun" then
		return (tags:AddTag("Status.Stunned"))
	elseif operation == "Unstun" then
		return (tags:RemoveTag("Status.Stunned"))
	elseif operation == "NPC" then
		local controller: ActionTypes.ActionController =
			npc:GetController("ActionController") :: ActionTypes.ActionController

		return controller:RequestAction("Fireball", { aim = 0 }).accepted
	end

	return false
end

report.OnServerEvent:Connect(function(player: Player, clientFailure: unknown, measurements: unknown): ()
	if finished or results[player.Name] ~= nil then
		return
	end

	if clientFailure ~= nil then
		finish(false, player.Name .. ":" .. tostring(clientFailure))

		return
	end

	results[player.Name] = measurements
	reported += 1

	if reported == 2 then
		finish(true)
	end
end)

for _, player: Player in Players:GetPlayers() do
	admit(player)
end

Players.PlayerAdded:Connect(admit)

task.delay(170, function(): ()
	finish(false, "PredictionNativeTimeout")
end)
