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
local schemas = require(ReplicatedStorage.ActionRequestSchemas)
local control: RemoteEvent = ReplicatedStorage:WaitForChild("ActionRequestControl") :: RemoteEvent

type Ledger = {
	fireballAims: { any },
	sprintStops: number,
	sprintInterrupts: number,
	castStops: { any },
	mountStarts: number,
}

local actors: { ActorTypes.Actor } = {}
local models: { Model } = {}
local characters: { [Player]: ActorTypes.Actor } = {}
local mounts: { [Player]: ActorTypes.Actor } = {}
local riders: { [ActorTypes.Actor]: Player } = {}
local ledgers: { [Player]: Ledger } = {}
local done: { [Player]: any } = {}
local finished: boolean = false

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

	local reports: { [string]: any } = {}

	for player: Player, report: any in done do
		reports[player.Name] = report
	end

	StudioTestService:EndTest({ success = success, reason = reason, reports = reports })
end

local function ledgerFor(actor: ActorTypes.Actor): Ledger?
	for player: Player, character: ActorTypes.Actor in characters do
		if character == actor or mounts[player] == actor then
			return ledgers[player]
		end
	end

	return nil
end

local function factory(definition: ActionTypes.ActionDefinition): ActionTypes.ActionFactory
	return function(): ActionTypes.ActionDefinition
		return table.clone(definition)
	end
end

local actions: { ActionTypes.ActionFactory } = {
	factory({
		id = "Combat.Fireball",
		visibility = "ClientVisible",
		autoGrant = true,
		onStart = function(context: ActionTypes.ActionExecutionContext): ()
			local ledger: Ledger? = ledgerFor(context.actor)

			if ledger ~= nil and context.parameters ~= nil then
				table.insert(ledger.fireballAims, context.parameters.aim)
			end

			context:End()
		end,
	}),
	factory({
		id = "Movement.Sprint",
		visibility = "ClientVisible",
		autoGrant = true,
		onStart = function(context: ActionTypes.ActionExecutionContext): ()
			local ledger: Ledger? = ledgerFor(context.actor)

			if ledger ~= nil and riders[context.actor] ~= nil then
				ledger.mountStarts += 1
			end
		end,
		onStopRequested = function(context: ActionTypes.ActionExecutionContext): ()
			local ledger: Ledger? = ledgerFor(context.actor)

			if ledger ~= nil then
				ledger.sprintStops += 1
			end

			context:End()
		end,
		onInterrupt = function(context: ActionTypes.ActionExecutionContext): ()
			local ledger: Ledger? = ledgerFor(context.actor)

			if ledger ~= nil then
				ledger.sprintInterrupts += 1
			end
		end,
	}),
	factory({
		id = "Technique.Cast",
		visibility = "ServerOnly",
		autoGrant = true,
		onStopRequested = function(
			context: ActionTypes.ActionExecutionContext,
			request: ActionTypes.ActionStopRequest
		): ()
			local ledger: Ledger? = ledgerFor(context.actor)

			if ledger ~= nil then
				table.insert(ledger.castStops, request.parameters)
			end

			context:End()
		end,
	}),
}

local function spawnModel(name: string, offset: number): Model
	local model: Model = Instance.new("Model")
	model.Name = name

	local root: Part = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Anchored = true
	root.CFrame = CFrame.new(offset, 0, 0)
	root.Parent = model
	model.PrimaryPart = root
	model.Parent = workspace
	table.insert(models, model)

	return model
end

local function verify(player: Player, report: any): string?
	local ledger: Ledger = ledgers[player]

	if type(report) ~= "table" or report.failure ~= nil then
		return "ClientReportedFailure:" .. tostring(if type(report) == "table" then report.failure else report)
	elseif #ledger.fireballAims ~= 1 or ledger.fireballAims[1].x ~= 1 then
		return "FireballTypedStartMissing"
	elseif ledger.sprintStops ~= 1 then
		return "SprintStopNotDeliveredOnce"
	elseif #ledger.castStops ~= 1 or ledger.castStops[1].releaseAim == nil then
		return "ServerOnlyCastStopMissing"
	elseif ledger.mountStarts ~= 1 or ledger.sprintInterrupts ~= 1 then
		return "DelegatedMountReceiptMissing"
	end

	return nil
end

control.OnServerEvent:Connect(function(player: Player, phase: any, payload: any): ()
	if finished then
		return
	end

	if phase == "Mount" then
		-- Server-owned delegation: the Character keeps its association.
		riders[mounts[player]] = player
		player:SetAttribute("MountActorId", mounts[player]:GetId())
	elseif phase == "Done" and done[player] == nil then
		done[player] = payload

		local failure: string? = verify(player, payload)

		if failure ~= nil then
			finish(false, player.Name .. ":" .. failure)

			return
		end

		for _, peer: Player in Players:GetPlayers() do
			if done[peer] == nil then
				return
			end
		end

		finish(#Players:GetPlayers() == 2, if #Players:GetPlayers() == 2 then nil else "NativePlayersMissing")
	end
end)

task.delay(60, function(): ()
	finish(false, "NativeActionRequestTimeout")
end)

local initialized: boolean, failure = Server.Init({
	actions = actions,
	actionRequestSchemas = schemas,
	actionControlAuthority = function(player: Player, actor: ActorTypes.Actor): boolean
		return riders[actor] == player
	end,
})

assert(initialized, if failure ~= nil then failure.reason else "NativeServerInitFailed")

local function admit(player: Player): ()
	local index: number = #actors + 1
	local character: Model = spawnModel("Character" .. index, index * 6)
	local characterActor: ActorTypes.Actor = assert(Actors.RegisterActor(character))
	local mount: ActorTypes.Actor = assert(Actors.RegisterActor(spawnModel("Mount" .. index, index * 6 + 3)))
	table.insert(actors, characterActor)
	table.insert(actors, mount)
	characters[player] = characterActor
	mounts[player] = mount
	ledgers[player] = { fireballAims = {}, sprintStops = 0, sprintInterrupts = 0, castStops = {}, mountStarts = 0 }
	player.Character = character
	player:SetAttribute("CharacterActorId", characterActor:GetId())
end

for _, player: Player in Players:GetPlayers() do
	admit(player)
end

Players.PlayerAdded:Connect(admit)
