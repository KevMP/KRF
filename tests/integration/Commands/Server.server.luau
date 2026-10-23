--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local StudioTestService = game:GetService("StudioTestService")
local KRF = ReplicatedStorage.Packages.KRF
local ActorTypes = require(KRF.server.Actor.types)
local NetworkingTypes = require(KRF.server.Networking.types)
local ReplicationTypes = require(KRF.server.Replication.types)
local SharedTypes = require(KRF.shared.Networking.types)
local Server = require(KRF.server)
local Actors: ActorTypes.ActorRuntime = require(KRF.server.Actor.ActorRuntime)
local Networking = require(KRF.server.Networking.ServerNetworking)
local Transport = require(KRF.shared.Networking.Transport)
local Protocol = require(KRF.shared.Networking.ProtocolCodec)
local ResyncCodec = require(KRF.shared.Networking.utils.ResyncCodec)
local Awareness: NetworkingTypes.ActorAwarenessRuntimeModule = require(KRF.server.Networking.ActorAwarenessRuntime)
local Schema: SharedTypes.Schema = require(KRF.shared.Networking.Schema)
local Authorization = require(KRF.server.Networking.CommandAuthorization)
local CommandCodec = require(KRF.shared.Networking.CommandCodec)
local CommandConstants = require(KRF.shared.Networking.utils.CommandConstants)
local Correlation = require(script.Parent.Utils.ServerCorrelation)
local control: RemoteEvent = ReplicatedStorage:WaitForChild("CommandTestControl") :: RemoteEvent

type Request = SharedTypes.CommandRequest

Players.CharacterAutoLoads = false

local actors: { [Player]: ActorTypes.Actor } = {}
local models: { Model } = {}
local reports: { [Player]: boolean } = {}
local requests: { [Player]: { Request } } = {}
local requestIds: { [Player]: { number } } = {}
local commandProtocol: SharedTypes.ClientProtocol? = nil
local awareness: NetworkingTypes.ActorAwarenessRuntime? = nil
local originalAwareness: typeof(Awareness.new) = Awareness.new
local originalPublish: typeof(Networking.Publish) = Networking.Publish
local phase: string = "Startup"
local finished: boolean = false
local listener: RBXScriptConnection? = nil

-- Capture the real startup owners without replacing their dependencies or
-- consumer installation. N4 receives NativePlayerAssociation from production.
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

Networking.Publish = function(protocol: SharedTypes.PreparedProtocol): (boolean, string?)
	commandProtocol = protocol.runtime

	return originalPublish(protocol)
end

local function finish(success: boolean, reason: string?): ()
	if finished then
		return
	end

	finished = true
	Awareness.new = originalAwareness
	Networking.Publish = originalPublish

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
	local runtime: NetworkingTypes.ActorAwarenessRuntime? = awareness
	assert(runtime ~= nil, "Expected production N4 association owner")

	for _, player: Player in players do
		local actor: ActorTypes.Actor = actors[player]
		assert(actor ~= nil and player.Character == actor.model, "Expected direct Character association")
		assert(runtime:GetActorForPlayer(player) == actor, "N4 must associate the actual Character Actor")
		assert(runtime:GetPlayerForActor(actor) == player, "N4 reverse association must identify the Player")
		local other: Player = if players[1] == player then players[2] else players[1]
		assert(runtime:IsAware(other, actor), "Other Ready clients remain aware without owning the Actor")
		-- OwnerActor is registered below for the production command path. Never
		-- call it with a synthetic context disconnected from this N4 owner.
	end

	phase = "Exercise"
	reports = {}

	for _, player: Player in players do
		control:FireClient(player, phase, actors[player]:GetId())
	end
end

control.OnServerEvent:Connect(function(player: Player, reportPhase: any, failure: any, sentIds: any): ()
	if finished then
		return
	end

	local completed: boolean, reason: any = pcall(function(): ()
		assert(failure == nil, tostring(failure))
		assert(reportPhase == phase, "Unexpected native command test phase")
		assert(not reports[player], "Duplicate native client report")

		if phase == "Exercise" then
			assert(type(sentIds) == "table" and #sentIds == 2, "Expected Send's two returned request ids")
			assert(type(sentIds[1]) == "number" and type(sentIds[2]) == "number", "Expected numeric request ids")
			requestIds[player] = sentIds
		end

		reports[player] = true

		if not allReported() then
			return
		end

		if phase == "Startup" then
			exercise()
		elseif phase == "Exercise" then
			for recipient: Player in actors do
				local deadline: number = os.clock() + 5

				while requests[recipient] == nil or #requests[recipient] < 2 do
					assert(os.clock() < deadline, "Expected command buffers on the native Reliable endpoint")
					task.wait()
				end

				assert(
					#requests[recipient] == 2,
					"Expected exactly two bounded command buffers on the existing Reliable endpoint"
				)

				for index: number, request: Request in requests[recipient] do
					assert(
						request.requestId == requestIds[recipient][index],
						"Decoded request id must equal Send's returned id"
					)
				end
			end

			local players: { Player } = Players:GetPlayers()
			phase = "PrepareCorrelation"
			reports = {}

			for _, recipient: Player in players do
				control:FireClient(
					recipient,
					phase,
					actors[players[1]]:GetId(),
					actors[players[2]]:GetId(),
					recipient == players[1]
				)
			end
		elseif phase == "PrepareCorrelation" then
			phase = "Correlation"
			reports = {}
			control:FireAllClients(phase)
		elseif phase == "Correlation" then
			for _, actor: ActorTypes.Actor in actors do
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
	finish(false, "Native command timeout in " .. phase .. "")
end)

local completed: boolean, reason: any = pcall(function(): ()
	local commands: { NetworkingTypes.CommandDefinition } = {
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
	}

	for _, command: NetworkingTypes.CommandDefinition in Correlation.Commands(actors) do
		table.insert(commands, command)
	end

	local initialized: boolean, failure: Server.StartupFailure? =
		Server.Init({ commands = commands, actions = Correlation.Actions })

	assert(initialized, if failure ~= nil then failure.reason else "Native Server.Init failed")
	local protocol: SharedTypes.ClientProtocol? = commandProtocol
	assert(protocol ~= nil and protocol.commandsById ~= nil, "Expected startup command codebook")
	local commandsById: { [string]: SharedTypes.ClientCommand } = protocol.commandsById
	local codec: SharedTypes.CommandCodec = CommandCodec.Compile(protocol)
	local owned: SharedTypes.OwnedTransport?, transportReason: string? = Transport.Locate(ReplicatedStorage)
	assert(owned ~= nil, transportReason)
	assert(#owned.root:GetDescendants() == 2, "N9 must reuse the existing Reliable and reserved Unreliable transports")

	listener = owned.reliable.OnServerEvent:Connect(function(player: Player, payload: any, ...: any): ()
		if finished then
			return
		end

		local extraArguments: number = select("#", ...)

		local captured: boolean, captureReason: any = pcall(function(): ()
			assert(
				extraArguments == 0 and typeof(payload) == "buffer" and buffer.len(payload) > 0,
				"Malformed Reliable envelope"
			)

			if buffer.readu8(payload, 0) ~= CommandConstants.REQUEST_KIND then
				assert(
					Protocol.Decode(payload) ~= nil or ResyncCodec.Decode(payload) ~= nil,
					"Unknown Reliable packet kind is not command traffic"
				)

				return
			end

			local request: Request?, decodeReason: string? = codec.DecodeRequest(payload)
			assert(request ~= nil and decodeReason == nil, "Malformed CommandRequest must not count as command traffic")

			assert(
				request.requestId >= 1 and request.requestId <= 4294967295 and request.requestId % 1 == 0,
				"Expected U32 request id"
			)

			local observed: { Request } = requests[player] or {}
			local index: number = #observed + 1

			if phase == "Retire" then
				assert(index == 3 or index == 8, "Expected one final native teardown probe per client")

				assert(
					request.commandCode == commandsById["Game.Ping"].code
						and request.targetHandle == nil
						and request.request == nil
						and request.requestId > observed[index - 1].requestId,
					"Expected decoded monotonic None-target teardown probe"
				)

				table.insert(observed, request)
				requests[player] = observed

				return
			end

			if index > 2 then
				assert(phase == "Correlation", "Unexpected command traffic outside the correlation phase")
				assert(index <= 7, "Unexpected correlation traffic")

				assert(
					commandsById["Game.Begin"].code == request.commandCode
						or commandsById["Game.Interrupt"].code == request.commandCode
						or commandsById["Game.Pulse"].code == request.commandCode
						or commandsById["Game.Follow"].code == request.commandCode,
					"Expected registered generic correlation command"
				)

				local runtime: NetworkingTypes.ActorAwarenessRuntime? = awareness
				assert(runtime ~= nil and request.targetHandle ~= nil, "Expected real private target")
				assert(runtime:ResolveActor(player, request.targetHandle) ~= nil, "Unknown private correlation target")

				for _, actor: ActorTypes.Actor in actors do
					assert(
						not string.find(buffer.tostring(payload), actor:GetId(), 1, true),
						"Correlation request leaked GUID"
					)
				end

				table.insert(observed, request)
				requests[player] = observed

				return
			end

			local commandId: string = if index == 1 then "Game.Ping" else "Game.Interact"

			assert(
				request.commandCode == commandsById[commandId].code,
				"Decoded command code must match the startup codebook"
			)

			if index == 1 then
				assert(
					request.targetHandle == nil and request.request == nil,
					"None-target command has no target or semantic payload"
				)
			else
				local runtime: NetworkingTypes.ActorAwarenessRuntime? = awareness
				assert(runtime ~= nil, "Expected live N4 runtime")
				local actor: ActorTypes.Actor = actors[player]
				local target: number? = runtime:GetHandle(player, actor)

				assert(
					target ~= nil and request.targetHandle == target,
					"Decoded target must equal this connection's private N4 handle"
				)

				local resolved: ActorTypes.Actor?, resolveReason: string? = runtime:ResolveActor(player, target)

				assert(
					resolved == actor and resolveReason == nil,
					"N4 must resolve the decoded target to the exact Actor"
				)

				assert(request.request.choice == 7, "Expected codec-validated request payload")
				assert(request.requestId > observed[1].requestId, "Request ids must increase")
			end

			for _, actor: ActorTypes.Actor in actors do
				assert(
					not string.find(buffer.tostring(payload), actor:GetId(), 1, true),
					"Recurring command leaked a public Actor GUID"
				)
			end

			-- Count only after kind, codec, codebook, id, target and privacy checks.
			table.insert(observed, request)
			requests[player] = observed
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
