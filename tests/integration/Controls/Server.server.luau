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
local schemas = require(ReplicatedStorage.ControlSchemas)
local control: RemoteEvent = ReplicatedStorage:WaitForChild("ControlTestReport") :: RemoteEvent
local probe: RemoteFunction = ReplicatedStorage:WaitForChild("ControlTestProbe") :: RemoteFunction

type Ledger = { starts: number, stops: number, interrupts: number, fireballs: number, releaseAim: number? }
local ledgers: { [Player]: Ledger } = {}
local owners: { [ActorTypes.Actor]: Player } = {}
local actors: { ActorTypes.Actor } = {}
local models: { Model } = {}
local reports: { [Player]: boolean } = {}
local finished: boolean = false

Players.CharacterAutoLoads = false

local function finish(success: boolean, reason: string?): ()
	if finished then
		return
	end

	finished = true

	for _, actor in actors do
		Actors.UnregisterActor(actor)
	end

	Networking.Destroy()

	for _, model in models do
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
		id = "Combat.Rasengan",
		visibility = "ServerOnly",
		autoGrant = true,
		onStart = function(context): ()
			ledgers[owners[context.actor]].starts += 1
		end,
		onStopRequested = function(context, request): ()
			local ledger: Ledger = ledgers[owners[context.actor]]
			ledger.stops += 1
			ledger.releaseAim = request.parameters.releaseAim
		end,
		onInterrupt = function(context): ()
			ledgers[owners[context.actor]].interrupts += 1
		end,
	}),
	factory({
		id = "Combat.Fireball",
		visibility = "ClientVisible",
		autoGrant = true,
		onStart = function(context): ()
			ledgers[owners[context.actor]].fireballs += 1
			context:End()
		end,
	}),
}

probe.OnServerInvoke = function(player: Player): Ledger
	return table.clone(ledgers[player])
end

control.OnServerEvent:Connect(function(player: Player, report: unknown): ()
	if finished or reports[player] then
		return
	end

	local failure: unknown = if type(report) == "table" then (report :: { [string]: unknown }).failure else report

	if type(report) ~= "table" or failure ~= nil then
		finish(false, "ControlsClientFailure:" .. tostring(failure))

		return
	end

	local ledger: Ledger = ledgers[player]

	if
		ledger.starts ~= 3
		or ledger.stops ~= 1
		or ledger.interrupts ~= 2
		or ledger.fireballs ~= 4
		or ledger.releaseAim ~= 8
	then
		finish(false, "OriginalActorLifecycleOrPrivacyMismatch")

		return
	end

	reports[player] = true

	local count: number = 0

	for _ in reports do
		count += 1
	end

	if count == 2 then
		finish(true)
	end
end)

local initialized: boolean, failure = Server.Init({
	actions = actions,
	actionRequestSchemas = schemas,
	actionControlAuthority = function(player: Player, actor: ActorTypes.Actor): boolean
		return owners[actor] == player
	end,
})

assert(initialized, if failure ~= nil then failure.reason else "ServerInitFailed")

local function spawn(player: Player, name: string): ActorTypes.Actor
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

	owners[actor] = player
	table.insert(actors, actor)

	return actor
end

local function admit(player: Player): ()
	ledgers[player] = { starts = 0, stops = 0, interrupts = 0, fireballs = 0 }

	local human: ActorTypes.Actor = spawn(player, player.Name .. ".Human")
	local mount: ActorTypes.Actor = spawn(player, player.Name .. ".Mount")

	player.Character = human.model
	player:SetAttribute("ControlHumanId", human:GetId())
	player:SetAttribute("ControlMountId", mount:GetId())
end

for _, player in Players:GetPlayers() do
	admit(player)
end

Players.PlayerAdded:Connect(admit)

if ReplicatedStorage:FindFirstChild("ControlManual") == nil then
	task.delay(60, function(): ()
		finish(false, "NativeControlsTimeout")
	end)
end
