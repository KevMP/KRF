--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local StudioTestService = game:GetService("StudioTestService")
local KRF = ReplicatedStorage.Packages.KRF
local ActorTypes = require(KRF.server.Actor.types)
local SharedTypes = require(KRF.shared.Networking.types)
local Server = require(KRF.server)
local Actors: ActorTypes.ActorRuntime = require(KRF.server.Actor.ActorRuntime)
local Networking = require(KRF.server.Networking.ServerNetworking)
local Transport = require(KRF.shared.Networking.Transport)
local Protocol = require(KRF.shared.Networking.ProtocolCodec)
local Schema: SharedTypes.Schema = require(KRF.shared.Networking.Schema)
local authorizationModule: Instance? = KRF.server:FindFirstChild("CommandAuthorization", true)
local requireOptional: (ModuleScript) -> any = require :: any

local Authorization: any = if authorizationModule ~= nil
	then requireOptional(authorizationModule :: ModuleScript)
	else nil

local control: RemoteEvent = ReplicatedStorage:WaitForChild("CommandTestControl") :: RemoteEvent

Players.CharacterAutoLoads = false

local actors: { [Player]: ActorTypes.Actor } = {}
local models: { Model } = {}
local reports: { [Player]: boolean } = {}
local requests: { [Player]: number } = {}
local phase: string = "Startup"
local finished: boolean = false
local listener: RBXScriptConnection? = nil

local function finish(success: boolean, reason: string?): ()
	if finished then
		return
	end

	finished = true

	local cleaned: boolean, cleanupReason: any = pcall(function(): ()
		if listener ~= nil then
			listener:Disconnect()
		end

		for _, actor: ActorTypes.Actor in actors do
			Actors.UnregisterActor(actor)
		end

		Networking.Destroy()

		for _, model: Model in models do
			model:Destroy()
		end
	end)

	StudioTestService:EndTest({
		success = success and cleaned,
		reason = reason or (if cleaned then nil else tostring(cleanupReason)),
		phase = phase,
	})
end

local function register(player: Player): ()
	if finished or actors[player] ~= nil then
		return
	end

	local model: Model = Instance.new("Model")
	model.Name = "CommandCharacter"
	model.Parent = workspace
	table.insert(models, model)
	local actor: ActorTypes.Actor?, reason: string? = Actors.RegisterActor(model)
	assert(actor ~= nil, reason)
	actors[player] = actor
	player.Character = model
end

local function allReported(): boolean
	local count: number = 0

	for _ in reports do
		count += 1
	end

	return count == 2
end

local function exercise(): ()
	local players: { Player } = Players:GetPlayers()
	assert(#players == 2, "Expected two real Players")

	for _, player: Player in players do
		local actor: ActorTypes.Actor = actors[player]
		assert(actor ~= nil and player.Character == actor.model, "Expected direct Character association")
		local allowed: boolean, reason: string? = Authorization.OwnerActor({ player = player, actor = actor }, nil)
		assert(allowed and reason == nil, "OwnerActor must accept the actual Character Actor")
		local other: Player = if players[1] == player then players[2] else players[1]
		allowed, reason = Authorization.OwnerActor({ player = other, actor = actor }, { ownerUserId = player.UserId })
		assert(not allowed and type(reason) == "string", "Awareness and client ownerUserId must not grant authority")
	end

	phase = "Exercise"
	reports = {}

	for _, player: Player in players do
		control:FireClient(player, phase, actors[player]:GetId())
	end
end

control.OnServerEvent:Connect(function(player: Player, reportPhase: any, failure: any): ()
	if finished then
		return
	end

	local completed: boolean, reason: any = pcall(function(): ()
		assert(failure == nil, tostring(failure))
		assert(reportPhase == phase, "Unexpected native command test phase")
		assert(not reports[player], "Duplicate native client report")
		reports[player] = true

		if not allReported() then
			return
		end

		if phase == "Startup" then
			exercise()
		elseif phase == "Exercise" then
			for recipient: Player, actor: ActorTypes.Actor in actors do
				local deadline: number = os.clock() + 5

				while (requests[recipient] or 0) < 2 do
					assert(os.clock() < deadline, "Expected command buffers on the native Reliable endpoint")
					task.wait()
				end

				assert(
					requests[recipient] == 2,
					"Expected exactly two bounded command buffers on the existing Reliable endpoint"
				)

				Actors.UnregisterActor(actor)
			end

			phase = "Retire"
			reports = {}
			control:FireAllClients(phase)
		elseif phase == "Retire" then
			Networking.Destroy()

			assert(
				ReplicatedStorage:FindFirstChild(Transport.ROOT_NAME) == nil,
				"Framework transport must be removed at shutdown"
			)

			finish(true, nil)
		end
	end)

	if not completed then
		finish(false, tostring(reason))
	end
end)

task.delay(75, function(): ()
	finish(false, "Native command foundations timeout")
end)

local completed: boolean, reason: any = pcall(function(): ()
	assert(Authorization ~= nil, "[N9 missing contract] CommandAuthorization helpers (#79.11-12)")

	local initialized: boolean, failure: Server.StartupFailure? = Server.Init({
		commands = {
			{
				id = "Game.Ping",
				target = "None",
				authorize = Authorization.AnyReadyClient,
				handle = function(): any
					return { accepted = true }
				end,
			},
			{
				id = "Game.Interact",
				target = "Actor",
				request = Schema.Struct({ choice = Schema.U8 }),
				authorize = Authorization.OwnerActor,
				handle = function(): any
					return { accepted = true }
				end,
			},
		},
	} :: any)

	assert(initialized, if failure ~= nil then failure.reason else "Native Server.Init failed")
	local owned: SharedTypes.OwnedTransport?, transportReason: string? = Transport.Locate(ReplicatedStorage)
	assert(owned ~= nil, transportReason)
	assert(#owned.root:GetDescendants() == 2, "N9 must reuse the existing Reliable and reserved Unreliable transports")

	listener = owned.reliable.OnServerEvent:Connect(function(player: Player, payload: any): ()
		if finished or typeof(payload) ~= "buffer" or Protocol.Decode(payload) ~= nil then
			return
		end

		local captured: boolean, captureReason: any = pcall(function(): ()
			for _, actor: ActorTypes.Actor in actors do
				assert(
					not string.find(buffer.tostring(payload), actor:GetId(), 1, true),
					"Recurring command leaked a public Actor GUID"
				)
			end

			requests[player] = (requests[player] or 0) + 1
		end)

		if not captured then
			finish(false, tostring(captureReason))
		end
	end)

	Players.PlayerAdded:Connect(register)

	for _, player: Player in Players:GetPlayers() do
		register(player)
	end
end)

if not completed then
	finish(false, tostring(reason))
end
