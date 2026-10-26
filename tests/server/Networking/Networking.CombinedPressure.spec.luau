--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local Types = require(KRF.server.Networking.types)
local ActorTypes = require(KRF.server.Actor.types)
local ActionTypes = require(KRF.server.Action.types)
local SharedTypes = require(KRF.shared.Networking.types)
local Server = require(KRF.server)
local ReplicationTypes = require(KRF.server.Replication.types)
local Association = require(KRF.server.Networking.utils.NativePlayerAssociation)
local Domains = require(KRF.server.Replication.ReplicationDomainRegistry)
local Networking = require(KRF.server.Networking.ServerNetworking)
local Installation = require(KRF.server.Networking.utils.NativeServerInstallation)
local Scheduling = require(KRF.server.Networking.utils.AwarenessScheduling)
local Awareness = require(KRF.server.Networking.ActorAwarenessRuntime)
local Commands = require(KRF.server.Networking.ServerCommandRuntime)
local Resync = require(KRF.server.Networking.ResyncRuntime)
local HintReceiver = require(KRF.server.Networking.ServerHintRuntime)
local HintSender = require(KRF.server.Networking.utils.HintSender)
local HintAuthorization = require(KRF.server.Networking.HintAuthorization)
local Diagnostics = require(KRF.server.Networking.NetworkingDiagnostics)
local DiagnosticState = require(KRF.server.Networking.utils.NetworkingDiagnosticsState)
local Transport = require(KRF.shared.Networking.Transport)
local Schema = require(KRF.shared.Networking.Schema)
local Wire = require(KRF.shared.Networking.ActorStreamCodec)
local HintWire = require(KRF.shared.Networking.HintCodec)
local CommandWire = require(KRF.shared.Networking.CommandCodec)
local ResyncWire = require(KRF.shared.Networking.utils.ResyncCodec)
local Constants = require(KRF.shared.Networking.utils.ProtocolConstants)
local CommandConstants = require(KRF.shared.Networking.utils.CommandConstants)
local HintConstants = require(KRF.shared.Networking.utils.HintConstants)
local ActorConstants = require(KRF.shared.Networking.utils.ActorProtocolConstants)
local ProtocolUtils = require(script.Parent.Parent.Parent.shared.Utils.Networking.ProtocolTestUtils)
local ActionUtils = require(script.Parent.Parent.Utils.Action.ActionResourceTestUtils)
local originalCreate, originalInstallation = Transport.Create, Installation.new
local originalStep, originalBudget = Scheduling.ObserveStep, Scheduling.GetBudget
local originalAwareness, originalCommands = Awareness.new, Commands.new
local originalResync, originalReceiver, originalSender = Resync.new, HintReceiver.new, HintSender.new
local originalPublish = Networking.Publish
local originalAssociation = Association.new
local instances: { Instance }

beforeEach(function()
	ActionUtils.reset()
	instances = {}
end)

afterEach(function()
	ActionUtils.cleanup()
	Transport.Create, Installation.new = originalCreate, originalInstallation
	Scheduling.ObserveStep, Scheduling.GetBudget = originalStep, originalBudget
	Awareness.new, Commands.new = originalAwareness, originalCommands
	Resync.new, HintReceiver.new, HintSender.new = originalResync, originalReceiver, originalSender
	Networking.Publish = originalPublish
	Association.new = originalAssociation

	for _, instance in instances do
		instance:Destroy()
	end
end)

it("isolates slow and joining recipients while Actions, commands, resync and disposable Hints compete", function()
	local now = 100
	local installed: Installation.Runtime? = nil
	local prepared: SharedTypes.PreparedProtocol? = nil
	local tick: (() -> ())? = nil
	local sent: { { player: Player, payload: buffer } } = {}
	local hintPackets = 0
	local received: { [Player]: number } = {}
	local executed: { [Player]: number } = {}
	local controllers: { [Player]: ActionTypes.ActionController } = {}
	local lastRequest: { [Player]: number } = {}
	local owners: { [Model]: Player } = {}
	local associationChanged: ((Model) -> ())? = nil

	-- Opaque simulated recipients use the existing dependency seam. Native tests
	-- retain the real Player association, consumer installer and both transports.
	Association.new = function(): Types.PlayerAssociationSource
		return {
			GetPlayerFromCharacter = function(model: Model): Player?
				return owners[model]
			end,
			ObserveAssociationChanged = function(callback: (Model) -> ()): () -> ()
				associationChanged = callback

				return function(): ()
					associationChanged = nil
				end
			end,
			Destroy = function() end,
		}
	end

	Transport.Create = function(): (SharedTypes.OwnedTransport?, string?)
		local root, reliable, unreliable =
			Instance.new("Folder"), Instance.new("BindableEvent"), Instance.new("BindableEvent")

		table.insert(instances, root)
		table.insert(instances, reliable)
		table.insert(instances, unreliable)

		return {
			root = root,
			reliable = {
				OnServerEvent = reliable.Event,
				FireClient = function(_self: any, player: Player, payload: buffer): ()
					table.insert(sent, { player = player, payload = payload })
				end,
			} :: any,
			unreliable = {
				OnServerEvent = unreliable.Event,
				FireClient = function(_self: any, _player: Player, payload: buffer): ()
					assert(buffer.len(payload) <= HintConstants.MAX_PACKET_BYTES, "Hint packet exceeded its ceiling")
					hintPackets += 1
					-- Deliberately drop every physical Hint packet. Reliable progress must not depend on it.
				end,
			} :: any,
			Destroy = function(): ()
				root:Destroy()
			end,
		},
			nil
	end

	Installation.new = function(transports)
		local owner = originalInstallation(transports)
		installed = owner

		return owner
	end

	Networking.Publish = function(protocol)
		prepared = protocol

		return originalPublish(protocol)
	end

	Scheduling.ObserveStep = function(callback): () -> ()
		tick = callback

		return function(): ()
			tick = nil
		end
	end

	Scheduling.GetBudget = function(): Types.AwarenessStepBudget
		return { maxBytes = 4096, maxRecords = 16 }
	end

	Awareness.new = function(
		publication: Types.PublicationRuntime,
		catalog: ReplicationTypes.PreparedReplicationDomainCatalog,
		protocol: SharedTypes.ClientProtocol,
		dependencies: Types.ActorAwarenessDependencies,
		options: Types.ActorAwarenessOptions
	): Types.ActorAwarenessRuntime
		dependencies.Now = function(): number
			return now
		end

		options.maxChunkBytes, options.maxEvents = 32, 64

		return originalAwareness(publication, catalog, protocol, dependencies, options)
	end

	Commands.new = function(catalog, protocol, dependencies)
		dependencies.Now = function(): number
			return now
		end

		return originalCommands(catalog, protocol, dependencies, {
			maxGlobalQueuedRequests = 16,
			maxGlobalQueuedBytes = 1024,
			maxDispatchRequests = 2,
			maxDispatchVisits = 4,
		})
	end

	Resync.new = function(dependencies, options)
		dependencies.Now = function(): number
			return now
		end

		return originalResync(dependencies, options)
	end

	HintReceiver.new = function(catalog, protocol, dependencies)
		dependencies.Now = function(): number
			return now
		end

		return originalReceiver(
			catalog,
			protocol,
			dependencies,
			{ maxRecords = 2, maxPendingPackets = 2, maxGlobalPendingPackets = 4 }
		)
	end

	HintSender.new = function(protocol, dependencies)
		dependencies.Now = function(): number
			return now
		end

		local limits = table.clone(HintConstants.SEND) :: Types.HintSendLimits
		limits.maxRecords, limits.maxConnectionRecords, limits.maxSends = 2, 1, 2
		limits.maxPending, limits.maxGlobalPending = 8, 16

		return originalSender(protocol, dependencies, limits)
	end

	local function receive(context: Types.HintContext): ()
		received[context.player] = (received[context.player] or 0) + 1
	end

	expect((Server.Init({
		actions = {
			function(): ActionTypes.ActionDefinition
				return {
					id = "Stress.Pulse",
					visibility = "ClientVisible",
					autoGrant = true,
					onStart = function(context): ()
						context:End()
					end,
				}
			end,
		},
		replicationDomains = {
			{
				id = "Stress.Padding",
				state = Schema.String(256),
				snapshot = function(): string
					return string.rep("x", 256)
				end,
			},
		},
		commands = {
			{
				id = "Stress.Command",
				target = "None",
				result = Schema.U32,
				authorize = function(): (boolean, string?)
					return true, nil
				end,
				handle = function(context: Types.CommandContext): Types.CommandHandlerResult
					local previous = lastRequest[context.player]

					if previous ~= nil then
						assert(
							assert(context:GetPriorOutcome(previous)).status == "Accepted",
							"Prior outcome was not installed"
						)
					end

					lastRequest[context.player] = context.requestId
					executed[context.player] = (executed[context.player] or 0) + 1

					local result = controllers[context.player]:RequestAction("Stress.Pulse")
					assert(result.accepted, "Expected authoritative Action acceptance")

					return { accepted = true, result = result.sequenceId }
				end,
			},
		},
		hints = {
			{
				id = "A.Input",
				direction = "ClientToServer",
				target = "Actor",
				mode = "Latest",
				payload = Schema.U8,
				authorize = HintAuthorization.OwnerActor,
				receive = receive,
			},
			{
				id = "B.Pulse",
				direction = "ClientToServer",
				target = "None",
				mode = "Pulse",
				payload = Schema.U8,
				authorize = HintAuthorization.AnyReadyClient,
				receive = receive,
			},
			{ id = "C.Sample", direction = "ServerToClient", target = "None", mode = "Latest", payload = Schema.U8 },
			{ id = "D.Pulse", direction = "ServerToClient", target = "None", mode = "Pulse", payload = Schema.U8 },
		},
	}))).toBe(true)

	local owner = assert(installed, "Expected normal server installation")
	local protocol = assert(prepared).runtime

	local handshake, awareness =
		assert(owner.runtime, "Expected handshake"), assert(owner.awareness, "Expected awareness")

	local commands, resync = assert(owner.commandRuntime, "Expected commands"), assert(owner.resync, "Expected resync")

	local receiver, sender =
		assert(owner.hintRuntime, "Expected C2S Hints"), assert(owner.hintSender, "Expected S2C Hints")

	local step = assert(tick, "Expected production scheduler driver")
	local actors: { ActorTypes.Actor } = {}
	local players: { Player } = {}
	local schemas: SharedTypes.ActorSchemaCatalog = {}

	for _, domain in Domains.GetAll() do
		schemas[domain.id] = domain.state
	end

	local actorWire, commandWire, hintWire =
		Wire.Compile(protocol, schemas), CommandWire.Compile(protocol), HintWire.Compile(protocol)

	for _ = 1, 16 do
		local actor = ActionUtils.registerActor()
		table.insert(actors, actor)
	end

	local function ready(player: Player): ()
		handshake:Handle(player, ProtocolUtils.encode({ kind = "Hello", version = Constants.PROTOCOL_VERSION }))
		handshake:Handle(player, ProtocolUtils.encode({ kind = "Ready" }))
		assert(handshake:IsClientReady(player))
	end

	for index = 1, 4 do
		local player = ProtocolUtils.createPlayer()
		player.Parent = Players
		table.insert(instances, player)
		table.insert(players, player)
		local model = assert(actors[index].model, "Expected Actor model")

		owners[model] = player
		assert(associationChanged, "Expected installed association observer")(model)
		controllers[player] = actors[index]:GetController("ActionController") :: ActionTypes.ActionController

		if index < 4 then
			ready(player)
		end
	end

	for _ = 1, 256 do
		step()
	end

	local before = assert(Diagnostics.GetServerSnapshot())
	expect(before.counters.baselinesCompleted).toBe(48)
	sent = {}
	local slow = assert(awareness:ReserveCommandResult(players[3], 1))
	ready(players[4])
	local admitted, refused = 0, 0
	local ordinaryEvents = 0
	local midpointSends = 0
	local ordinary = actors[5]:GetController("ActionController") :: ActionTypes.ActionController

	for pump = 1, 96 do
		-- A new deterministic admission window; no wall-clock rate assumptions.
		now += 1

		for attempt = 1, 12 do
			local request =
				assert(commandWire.EncodeRequest({ requestId = (pump - 1) * 12 + attempt, commandCode = 0 }))

			if commands:Handle(players[1], request) then
				admitted += 1
			else
				refused += 1
			end
		end

		if pump % 8 == 0 then
			local request = assert(commandWire.EncodeRequest({ requestId = pump, commandCode = 0 }))
			expect((commands:Handle(players[2], request))).toBe(true)
			admitted += 1
		end

		if pump % 4 == 0 then
			assert(ordinary:RequestAction("Stress.Pulse").accepted, "Expected ordinary Actor progress")
		end

		local handle = assert(awareness:GetHandle(players[1], actors[1]))
		local resyncPacket = assert(ResyncWire.Encode(handle))

		for _ = 1, 8 do
			resync:Handle(players[1], resyncPacket)
		end

		for _, player in { players[1], players[2] } do
			local target = assert(awareness:GetHandle(player, actors[1]))

			local records = {
				assert(hintWire.EncodeRecord({ hintCode = 0, targetHandle = target, sequence = pump, payload = 1 })),
				assert(hintWire.EncodeRecord({ hintCode = 0, targetHandle = target, sequence = pump, payload = 1 })),
				assert(hintWire.EncodeRecord({ hintCode = 1, payload = 2 })),
			}

			local packet = assert(hintWire.Pack(records))
			receiver:Handle(player, packet)

			for value = 1, 12 do
				sender:SendTo(player, "C.Sample", nil, value)
				sender:SendTo(player, "D.Pulse", nil, value)
			end
		end

		step()
		local work = (awareness :: any).delivery.work

		if work ~= nil then
			for unit, used in work.used do
				assert(used <= work.limits[unit], "Exceeded attempted reliable work budget")
			end
		end

		local jobs, bytes = commands:_GetPendingForTests()
		assert(jobs <= 16 and bytes <= 1024, "Exceeded aggregate command ownership")
		local snapshot = assert(Diagnostics.GetServerSnapshot())

		assert(
			snapshot.gauges.hintSendRecords.current <= 16 and snapshot.gauges.hintReceivePackets.current <= 4,
			"Exceeded Hint ownership"
		)

		assert(
			snapshot.gauges.reliableRecords.current <= ActorConstants.BACKLOG_RECORDS,
			"Exceeded reliable record ownership"
		)

		assert(
			snapshot.gauges.reliableRetainedBytes.current <= ActorConstants.BACKLOG_BYTES,
			"Exceeded reliable byte ownership"
		)

		if pump == 48 then
			midpointSends = #sent
			slow.Cancel()
		end
	end

	local pressured = assert(Diagnostics.GetServerSnapshot())
	local ordinaryDuringPressure = 0
	local joiningOrdinaryDuringPressure = 0
	local ordinaryBeforeRelease = 0
	local ordinaryHandle = awareness:GetHandle(players[2], actors[5])
	local joiningOrdinaryHandle = awareness:GetHandle(players[4], actors[5])

	for index, delivery in sent do
		if
			(delivery.player == players[2] or delivery.player == players[4])
			and buffer.readu8(delivery.payload, 0) == ActorConstants.PACKET_KIND
		then
			for _, record in assert(actorWire.Decode(delivery.payload)) do
				if delivery.player == players[2] and record.kind == "Commit" and record.handle == ordinaryHandle then
					ordinaryDuringPressure += #record.events

					if index <= midpointSends then
						ordinaryBeforeRelease += #record.events
					end
				end

				if
					delivery.player == players[4]
					and record.kind == "Commit"
					and record.handle == joiningOrdinaryHandle
				then
					joiningOrdinaryDuringPressure += #record.events
				end
			end
		end
	end

	print("__KRF_STRUCTURAL_PRESSURE__ " .. HttpService:JSONEncode({
		admitted = admitted,
		ordinaryDuringPressure = ordinaryDuringPressure,
		joiningOrdinaryDuringPressure = joiningOrdinaryDuringPressure,
		ordinaryBeforeRelease = ordinaryBeforeRelease,
		refused = refused,
		executedHot = executed[players[1]],
		executedIntermittent = executed[players[2]],
		counters = pressured.counters,
		gauges = pressured.gauges,
		maxima = pressured.maxima,
	}))

	expect(ordinaryBeforeRelease > 0).toBe(true)
	expect(ordinaryDuringPressure > ordinaryBeforeRelease).toBe(true)
	expect(joiningOrdinaryDuringPressure > 0).toBe(true)
	expect(pressured.counters.baselinesCompleted > before.counters.baselinesCompleted).toBe(true)
	expect(pressured.counters.hintsCoalesced > 0 and pressured.counters.hintsDropped > 0).toBe(true)
	expect(pressured.counters.hintsUnauthorized > 0 and pressured.counters.hintsStaleDropped > 0).toBe(true)
	expect(pressured.counters.resyncDeduplicated > 0 and pressured.counters.resyncRateLimited > 0).toBe(true)
	expect(refused > 0 and admitted > 0).toBe(true)
	expect(executed[players[1]] > 0).toBe(true)
	expect(executed[players[2]]).toBe(12)
	expect(received[players[1]] > 0 and received[players[2]] > 0 and hintPackets > 0).toBe(true)
	expect(pressured.maxima.commandPumpWorkUnits <= 4).toBe(true)
	expect(pressured.maxima.hintSendPumpWorkUnits <= 2 and pressured.maxima.hintReceivePumpWorkUnits <= 2).toBe(true)

	for _ = 1, 512 do
		now += 1
		step()
	end

	local correlated: { [number]: boolean } = {}
	local requesterEvents = 0
	local joiningOrdinaryEvents = 0
	local requesterHandle = awareness:GetHandle(players[2], actors[2])
	local completedJoins: { [number]: boolean } = {}

	for _, delivery in sent do
		if buffer.readu8(delivery.payload, 0) == CommandConstants.RESULT_KIND then
			if delivery.player == players[2] then
				local result = assert(commandWire.DecodeResult(delivery.payload))
				assert(result.status == "Accepted", "Expected definitive requester acceptance")
				correlated[result.result] = true
			end
		elseif buffer.readu8(delivery.payload, 0) == ActorConstants.PACKET_KIND then
			for _, record in assert(actorWire.Decode(delivery.payload)) do
				if
					delivery.player == players[4]
					and record.kind == "Commit"
					and record.handle == joiningOrdinaryHandle
				then
					joiningOrdinaryEvents += #record.events
				end

				if delivery.player == players[4] and record.kind == "BaselineEnd" then
					completedJoins[record.handle] = true
				end

				if delivery.player == players[2] and record.kind == "Commit" then
					for _, event in record.events do
						if event.domainId == "KRF.Actions" then
							if record.handle == ordinaryHandle then
								ordinaryEvents += 1
							end

							if record.handle == requesterHandle then
								requesterEvents += 1

								assert(
									correlated[event.payload.sequenceId],
									"Action callback work overtook its command result"
								)
							end
						end
					end
				end
			end
		end
	end

	local joins = 0

	for _ in completedJoins do
		joins += 1
	end

	expect(joins).toBe(16)
	expect(ordinaryEvents).toBe(48)
	expect(requesterEvents).toBe(24)
	expect(joiningOrdinaryEvents).toBe(48)
	expect((commands:_GetPendingForTests())).toBe(0)
	local drained = assert(Diagnostics.GetServerSnapshot())
	expect(drained.counters.commandsExecuted).toBe(admitted)
	expect(drained.counters.commandsAccepted).toBe(admitted)
	expect(drained.counters.commandsRejected).toBe(0)
	expect(drained.counters.commandsFaulted).toBe(0)
	expect(drained.counters.commandsUncertain).toBe(0)
	expect(drained.counters.commandsAbandoned).toBe(0)
	expect(drained.gauges.commandResultSlots.current).toBe(0)
	expect(drained.gauges.reliableRecords.current).toBe(0)
	expect(drained.gauges.reliableRetainedBytes.current).toBe(0)

	print("__KRF_STRUCTURAL_DRAIN__ " .. HttpService:JSONEncode({
		admitted = admitted,
		executed = drained.counters.commandsExecuted,
		accepted = drained.counters.commandsAccepted,
		joins = joins,
		ordinaryEvents = ordinaryEvents,
		requesterEvents = requesterEvents,
		joiningOrdinaryEvents = joiningOrdinaryEvents,
		gauges = drained.gauges,
	}))

	local collector = assert(DiagnosticState.GetServer())
	Networking.Destroy()

	local gauges = collector:Snapshot().gauges

	for _, gauge in
		{
			gauges.connections,
			gauges.readyConnections,
			gauges.awareStreams,
			gauges.reliableRecords,
			gauges.reliableRetainedBytes,
			gauges.reliableDeliveryBytes,
			gauges.reliableActiveConnections,
			gauges.reliableActiveStreams,
			gauges.baselineGenerations,
			gauges.recoveryStreams,
			gauges.commandRequests,
			gauges.commandBytes,
			gauges.commandResultSlots,
			gauges.commandResultReservedBytes,
			gauges.commandFencedRecords,
			gauges.commandFencedBytes,
			gauges.commandHistoryEntries,
			gauges.commandHistoryBytes,
			gauges.hintSendRecords,
			gauges.hintSendBytes,
			gauges.hintReceivePackets,
			gauges.hintReceiveBytes,
			gauges.hintLatestKeys,
			gauges.publicationQueuedRecords,
			gauges.publicationQueuedBytes,
		}
	do
		expect(gauge.current).toBe(0)
	end
end)
