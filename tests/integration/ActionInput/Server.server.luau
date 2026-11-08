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
local schemas = require(ReplicatedStorage.ActionInputSchemas)
local control: RemoteEvent = ReplicatedStorage:WaitForChild("ActionInputControl") :: RemoteEvent
local probe: RemoteFunction = ReplicatedStorage:WaitForChild("ActionInputProbe") :: RemoteFunction

type Ledger = {
	starts: { number },
	releases: { number },
	interrupts: number,
	fireballs: { number },
	auraStarts: number,
	auraStops: number,
	oneShots: number,
	keeps: number,
	contexts: { ActionTypes.ActionExecutionContext },
	aura: ActionTypes.ActionExecutionContext?,
}

local actors: { ActorTypes.Actor } = {}
local models: { Model } = {}
local ledgers: { [ActorTypes.Actor]: Ledger } = {}
local owned: { [Player]: ActorTypes.Actor } = {}
local reports: { [Player]: any } = {}
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

	StudioTestService:EndTest({ success = success, reason = reason })
end

local function factory(definition: ActionTypes.ActionDefinition): ActionTypes.ActionFactory
	return function(): ActionTypes.ActionDefinition
		return table.clone(definition)
	end
end

local actions: { ActionTypes.ActionFactory } = {
	factory({
		id = "Combat.Keep",
		visibility = "ServerOnly",
		autoGrant = true,
		onStart = function(context: ActionTypes.ActionExecutionContext): ()
			context:End()

			if not context:IsActive() then
				ledgers[context.actor].keeps += 1
			end
		end,
	}),
	factory({
		id = "Combat.OneShot",
		visibility = "ServerOnly",
		autoGrant = true,
		onStart = function(context: ActionTypes.ActionExecutionContext): ()
			context:End()

			if not context:IsActive() then
				ledgers[context.actor].oneShots += 1
			end
		end,
	}),
	factory({
		id = "Combat.Rasengan",
		visibility = "ServerOnly",
		autoGrant = true,
		onStart = function(context: ActionTypes.ActionExecutionContext): ()
			local ledger: Ledger = ledgers[context.actor]
			table.insert(ledger.starts, context.parameters.aim)
			table.insert(ledger.contexts, context)
		end,
		onStopRequested = function(
			context: ActionTypes.ActionExecutionContext,
			request: ActionTypes.ActionStopRequest
		): ()
			table.insert(ledgers[context.actor].releases, request.parameters.releaseAim)
			-- Deliberately remain active: input Stop is not authoritative End.
		end,
		onInterrupt = function(context: ActionTypes.ActionExecutionContext): ()
			ledgers[context.actor].interrupts += 1
		end,
	}),
	factory({
		id = "Combat.Fireball",
		visibility = "ClientVisible",
		autoGrant = true,
		onCanStart = function(context: ActionTypes.ActionStartContext): (boolean, string?)
			return context.parameters.aim ~= 99, if context.parameters.aim == 99 then "GameDenied" else nil
		end,
		onStart = function(context: ActionTypes.ActionExecutionContext): ()
			table.insert(ledgers[context.actor].fireballs, context.parameters.aim)
			context:End()
		end,
	}),
	factory({ id = "Movement.Sprint", visibility = "ServerOnly", autoGrant = false }),
	factory({
		id = "Mode.Aura",
		visibility = "ServerOnly",
		autoGrant = true,
		onStart = function(context: ActionTypes.ActionExecutionContext): ()
			local ledger: Ledger = ledgers[context.actor]
			ledger.auraStarts += 1
			ledger.aura = context
		end,
		onStopRequested = function(context: ActionTypes.ActionExecutionContext): ()
			ledgers[context.actor].auraStops += 1
		end,
	}),
}

probe.OnServerInvoke = function(player: Player): any
	local ledger: Ledger = ledgers[owned[player]]
	local first: ActionTypes.ActionExecutionContext? = ledger.contexts[1]
	local latest: ActionTypes.ActionExecutionContext? = ledger.contexts[#ledger.contexts]

	return {
		starts = table.clone(ledger.starts),
		releases = table.clone(ledger.releases),
		interrupts = ledger.interrupts,
		fireballs = table.clone(ledger.fireballs),
		auraStarts = ledger.auraStarts,
		auraStops = ledger.auraStops,
		releasedStillActive = first ~= nil and first:IsActive(),
		latestStillActive = latest ~= nil and latest:IsActive(),
		auraStillActive = ledger.aura ~= nil and ledger.aura:IsActive(),
	}
end

control.OnServerEvent:Connect(function(player: Player, report: any): ()
	if finished or reports[player] ~= nil then
		return
	end

	reports[player] = report

	if type(report) ~= "table" or report.failure ~= nil then
		finish(
			false,
			"ClientActionInputFailure:" .. tostring(if type(report) == "table" then report.failure else report)
		)

		return
	end

	local ledger: Ledger = ledgers[owned[player]]

	if
		#ledger.starts ~= 85
		or #ledger.releases ~= 3
		or ledger.releases[1] ~= 8
		or ledger.releases[3] ~= 17
		or ledger.interrupts ~= 82
	then
		finish(false, "OriginalActionLifecycleMismatch")

		return
	elseif #ledger.fireballs ~= 2 or ledger.fireballs[1] ~= 8 or ledger.fireballs[2] ~= 12 then
		finish(false, "ConcreteActionParametersOrAuthorityMismatch")

		return
	elseif ledger.auraStarts ~= 1 or ledger.auraStops ~= 1 or ledger.aura == nil or not ledger.aura:IsActive() then
		finish(false, "ToggleStopMustRemainNonterminal")

		return
	elseif ledger.oneShots ~= 80 then
		finish(false, "RepeatableOneShotCapacityExhausted")

		return
	elseif ledger.keeps ~= 80 then
		finish(false, "KeepDetachmentCapacityExhausted")

		return
	end

	for _, peer: Player in Players:GetPlayers() do
		if reports[peer] == nil then
			return
		end
	end

	finish(#Players:GetPlayers() == 2, if #Players:GetPlayers() == 2 then nil else "ExpectedTwoNativeClients")
end)

task.delay(60, function(): ()
	finish(false, "NativeActionInputTimeout")
end)

local initialized: boolean, failure = Server.Init({ actions = actions, actionRequestSchemas = schemas })
assert(initialized, if failure ~= nil then failure.reason else "NativeServerInitFailed")

local function admit(player: Player): ()
	local model: Model = Instance.new("Model")
	model.Name = player.Name

	local root: Part = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Anchored = true
	root.CFrame = CFrame.new(#actors * 6, 0, 0)
	root.Parent = model
	model.PrimaryPart = root
	model.Parent = workspace
	table.insert(models, model)
	local actor: ActorTypes.Actor = assert(Actors.RegisterActor(model))

	owned[player] = actor

	ledgers[actor] = {
		starts = {},
		releases = {},
		interrupts = 0,
		fireballs = {},
		auraStarts = 0,
		auraStops = 0,
		oneShots = 0,
		keeps = 0,
		contexts = {},
	}

	table.insert(actors, actor)
	player.Character = model
	player:SetAttribute("ActionInputActorId", actor:GetId())
end

for _, player: Player in Players:GetPlayers() do
	admit(player)
end

Players.PlayerAdded:Connect(admit)
