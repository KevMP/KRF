--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")
local StudioTestService = game:GetService("StudioTestService")
local KRF = ReplicatedStorage.Packages.KRF
local Scheduling = require(KRF.server.Networking.utils.AwarenessScheduling)
local Types = require(KRF.server.Networking.types)
local ActorTypes = require(KRF.server.Actor.types)
local TagTypes = require(KRF.server.Tags.types)
local SharedTypes = require(KRF.shared.Networking.types)
local ReplicationTypes = require(KRF.server.Replication.types)
local Server = require(KRF.server)
local Actors = require(KRF.server.Actor.ActorRuntime)
local Networking = require(KRF.server.Networking.ServerNetworking)
local Commands = require(KRF.server.Networking.ServerCommandRuntime)
local Awareness = require(KRF.server.Networking.ActorAwarenessRuntime)
local ActorConstants = require(KRF.shared.Networking.utils.ActorProtocolConstants)
local CommandCodec = require(KRF.shared.Networking.CommandCodec)
local Authorization = require(KRF.server.Networking.CommandAuthorization)
local Scenario = require(ReplicatedStorage.NetworkingCommandScenario)
local Baseline = require(ReplicatedStorage.NetworkingBaselineScenario)
local Constants = require(KRF.shared.Networking.utils.CommandConstants)
local control: RemoteEvent = ReplicatedStorage:WaitForChild("NetworkingBaselineControl") :: RemoteEvent
local args = StudioTestService:GetTestArgs()
local clientCount = if type(args) == "table" then args.clientCount else 2
assert(clientCount == 2 or clientCount == 4 or clientCount == 6 or clientCount == 8, "Invalid native count")

Scheduling.GetBudget = function(): Types.AwarenessStepBudget
	local bytes, records = Baseline.budget()

	return { maxBytes = bytes, maxRecords = records }
end

Players.CharacterAutoLoads = false

local ready: { [Player]: boolean } = {}
local replies: { [Player]: any } = {}
local actors: { [Player]: ActorTypes.Actor } = {}
local models: { Model } = {}
local cases: { any } = {}
local requests: { [Player]: { [number]: any } } = {}
local executed: { [Player]: { number } } = {}
local last: { [Player]: number } = {}
local ingressUs, dispatchUs, handlerUs, dispatchWaitMs, frames, heap = {}, {}, {}, {}, {}, {}
local dispatchCounts, dispatchVisits = {}, {}
local rejected: { [string]: number } = {}
local runtime: Types.ServerCommandRuntime? = nil
local awareness: Types.ActorAwarenessRuntime? = nil
local measuring, finished = false, false
local phase = "Ready"
local epoch = 0
local calls, offered, admitted, ingressHandlers = 0, 0, 0, 0
local peakJobs, peakBytes, peakResults, peakResultBytes = 0, 0, 0, 0
local others: { [Player]: number } = {}
local maxOthers = 0
local blockedReservations = 0
local originalNew = Commands.new
local originalStep = Awareness.Step
local originalAwarenessNew = Awareness.new
local egressUs, workSamples = {}, {}
local sendAttempts, physicalSends, logicalActorRecords, resultRecords, payloadBytes = 0, 0, 0, 0, 0

Awareness.Step = function(...: any): ()
	local started = os.clock()
	originalStep(...)
	local elapsed = (os.clock() - started) * 1e6

	if measuring then
		table.insert(egressUs, elapsed)
		table.insert(workSamples, Baseline.work((...)))
	end
end

Awareness.new = function(
	publication: Types.PublicationRuntime,
	catalog: ReplicationTypes.PreparedReplicationDomainCatalog,
	protocol: SharedTypes.ClientProtocol,
	dependencies: Types.ActorAwarenessDependencies,
	options: Types.ActorAwarenessOptions
): Types.ActorAwarenessRuntime
	local observed = table.clone(dependencies)
	local send = dependencies.SendReliable

	observed.SendReliable = function(player: Player, payload: buffer): (boolean, string?)
		local sent, reason = send(player, payload)

		if measuring then
			sendAttempts += 1

			if sent then
				physicalSends += 1
				payloadBytes += buffer.len(payload)

				if buffer.readu8(payload, 0) == ActorConstants.PACKET_KIND then
					logicalActorRecords += buffer.readu32(payload, 5)
				else
					resultRecords += 1
				end
			end
		end

		return sent, reason
	end

	return originalAwarenessNew(publication, catalog, protocol, observed, options)
end

local function pending(): number
	if runtime == nil then
		return 0
	end

	local internal: any = runtime
	local jobs, bytes = 0, 0

	if type(internal._GetPendingForTests) == "function" then
		jobs, bytes = (runtime :: Types.ServerCommandRuntime):_GetPendingForTests()
	else
		for _, connection in internal.connections do
			jobs += #connection.queue
			bytes += connection.queuedBytes
		end
	end

	peakJobs, peakBytes = math.max(peakJobs, jobs), math.max(peakBytes, bytes)
	local results, resultBytes = 0, 0
	local outbound: any = awareness

	if outbound ~= nil then
		for _, connection in outbound.connections do
			results += #connection.egress.queue
			resultBytes += connection.egress.reservedBytes
		end
	end

	peakResults, peakResultBytes = math.max(peakResults, results), math.max(peakResultBytes, resultBytes)

	return jobs
end

Commands.new = function(
	catalog: Types.PreparedCommandCatalog,
	protocol: SharedTypes.ClientProtocol,
	dependencies: Types.ServerCommandDependencies,
	options: Types.ServerCommandLimits?
): Types.ServerCommandRuntime
	local created = originalNew(catalog, protocol, dependencies, options)
	runtime, awareness = created, dependencies.awareness
	local reserve = dependencies.awareness.ReserveCommandResult

	dependencies.awareness.ReserveCommandResult = function(
		self: Types.ActorAwarenessRuntime,
		player: Player,
		maximum: number
	): (Types.CommandReservation?, string?)
		local token, reason = reserve(self, player, maximum)

		if measuring and token == nil then
			blockedReservations += 1
		end

		return token, reason
	end

	local codec = CommandCodec.Compile(protocol)
	local handle = created.Handle

	created.Handle = function(
		self: Types.ServerCommandRuntime,
		player: Player,
		payload: any,
		...: any
	): (boolean, string?)
		if not measuring then
			return handle(self, player, payload, ...)
		end

		local request = assert(codec.DecodeRequest(payload))

		requests[player] = requests[player] or {}

		local record = {
			at = os.clock(),
			accepted = false,
			executed = false,
			serial = request.request.serial,
			window = math.max(0, math.floor(workspace:GetServerTimeNow() - epoch)),
		}

		requests[player][request.requestId] = record
		local before, started = calls, os.clock()
		local accepted, reason = handle(self, player, payload, ...)
		table.insert(ingressUs, (os.clock() - started) * 1e6)
		ingressHandlers += calls - before
		offered += 1
		record.accepted = accepted

		if accepted then
			admitted += 1
		else
			rejected[reason or "Unknown"] = (rejected[reason or "Unknown"] or 0) + 1
		end

		pending()

		return accepted, reason
	end

	local internal: any = created

	if internal.Step ~= nil then
		local step = created.Step

		created.Step = function(self: Types.ServerCommandRuntime): (number, number)
			local started = os.clock()
			local dispatched, visits = step(self)

			if measuring then
				table.insert(dispatchUs, (os.clock() - started) * 1e6)
				table.insert(dispatchCounts, dispatched)
				table.insert(dispatchVisits, visits)
				pending()
			end

			return dispatched, visits
		end
	end

	return created
end

local heartbeat = RunService.Heartbeat:Connect(function(delta: number)
	if measuring then
		table.insert(frames, delta * 1000)
		table.insert(heap, gcinfo())
	end
end)

local function finish(success: boolean, reason: string?): ()
	if finished then
		return
	end

	finished, measuring = true, false
	Commands.new = originalNew
	Awareness.Step = originalStep
	Awareness.new = originalAwarenessNew
	heartbeat:Disconnect()

	local cleaned, cleanupReason = pcall(function()
		for _, actor in actors do
			Actors.UnregisterActor(actor)
		end

		Networking.Destroy()

		for _, model in models do
			model:Destroy()
		end
	end)

	StudioTestService:EndTest({
		success = success and cleaned,
		reason = reason or (if cleaned then nil else tostring(cleanupReason)),
		phase = phase,
		clients = clientCount,
		profile = "CommandsNative",
		workloadVersion = Scenario.version,
		cases = cases,
	})
end

local function waitFor(predicate: () -> boolean, reason: string, seconds: number?): ()
	local deadline = os.clock() + (seconds or 45)

	while not predicate() do
		assert(not finished and os.clock() < deadline, reason)
		task.wait(0.01)
	end
end

local function count(entries: any): number
	local total = 0

	for _ in entries do
		total += 1
	end

	return total
end

control.OnServerEvent:Connect(function(player: Player, payload: buffer)
	local success, reason = pcall(function()
		local message = HttpService:JSONDecode(buffer.tostring(payload))
		assert(message.failure == nil, tostring(message.failure))

		if message.kind == "Ready" then
			assert(Networking.IsClientReady(player) and not ready[player], "Bad native READY")
			ready[player] = true
		else
			assert(ready[player] and message.phase == phase and replies[player] == nil, "Wrong/duplicate phase")
			message.clientId = player.UserId
			replies[player] = message
		end
	end)

	if not success then
		finish(false, tostring(reason))
	end
end)

local function request(kind: string, extra: any?): ()
	phase = tostring(#cases) .. ":" .. kind
	replies = {}

	local message = extra or {}
	message.kind, message.phase = kind, phase

	for player in ready do
		message.actorId = if actors[player] ~= nil then actors[player]:GetId() else nil
		control:FireClient(player, buffer.fromstring(HttpService:JSONEncode(message)))
	end

	waitFor(function(): boolean
		return count(replies) == clientCount
	end, "Missing native " .. kind)
end

local success, reason = pcall(function()
	local initialized, startupFailure = Server.Init({
		tags = {
			{
				id = "Bench.Command",
				visibility = "ClientVisible",
				duplicateBehavior = "Refresh",
				defaultDuration = 10000,
			},
		},
		commands = {
			{
				id = "Bench.Command",
				target = "Actor",
				request = Scenario.request,
				result = Scenario.result,
				authorize = Authorization.OwnerActor,
				handle = function(context: Types.CommandContext, requestData: any): Types.CommandHandlerResult
					local started = os.clock()
					local actor = context.actor :: ActorTypes.Actor
					local controller = actor:GetController("TagController") :: TagTypes.TagController

					assert(
						controller:AddTag(
							"Bench.Command",
							{ duration = epoch + 10000 + requestData.serial * 100 - workspace:GetServerTimeNow() }
						)
					)

					table.insert(handlerUs, (os.clock() - started) * 1e6)
					assert(measuring and actors[context.player] == actor, "Wrong native command target")
					local previous = last[context.player]

					if previous ~= nil then
						assert(
							context.requestId > previous and context:GetPriorOutcome(previous) ~= nil,
							"Lost request order/history"
						)
					end

					last[context.player] = context.requestId

					local record = requests[context.player][context.requestId]
					record.executed = true
					calls += 1
					executed[context.player] = executed[context.player] or {}
					table.insert(executed[context.player], context.requestId)
					table.insert(dispatchWaitMs, (os.clock() - record.at) * 1000)
					local internal: any = runtime

					for player, connection in internal.connections do
						local outbound: any = awareness
						local egress = outbound.connections[player].egress

						local eligible = not egress.destroyed
							and egress.scope == nil
							and #egress.queue < Constants.MAX_OUTBOUND_RESULTS
							and egress.reservedBytes + 9 + Constants.MAX_REASON_BYTES <= Constants.MAX_OUTBOUND_BYTES
							and egress.order < Constants.MAX_COUNTER

						if player == context.player or #connection.queue == 0 or not eligible then
							others[player] = 0
						else
							others[player] = (others[player] or 0) + 1
							maxOthers = math.max(maxOthers, others[player])
						end
					end

					return { accepted = true, result = { serial = requestData.serial } }
				end,
			},
		},
	})

	assert(initialized, if startupFailure ~= nil then startupFailure.reason else "Native server startup failed")
end)

if not success then
	finish(false, tostring(reason))
else
	task.delay(240, function()
		finish(false, "Native command benchmark timed out")
	end)

	task.spawn(function()
		local completed, failure = pcall(function()
			waitFor(function(): boolean
				return #Players:GetPlayers() == clientCount and count(ready) == clientCount
			end, "Expected all native clients ready", 90)

			local players = Players:GetPlayers()

			table.sort(players, function(a: Player, b: Player)
				return a.UserId < b.UserId
			end)

			for index, player in players do
				local model = Instance.new("Model")

				local part = Instance.new("Part")
				part.Anchored, part.Position, part.Parent = true, Vector3.new(index * 8, 5, 0), model
				model.PrimaryPart, model.Parent = part, workspace
				player.Character = model
				table.insert(models, model)
				local actor = assert(Actors.RegisterActor(model))

				actors[player] = actor

				local controller = actor:GetController("TagController") :: TagTypes.TagController
				assert(controller:AddTag("Bench.Command"))
			end

			request("Prepare", { clients = clientCount })
			task.wait(2)

			for _, mode in Scenario.modes do
				requests, executed, last, rejected, others = {}, {}, {}, {}, {}
				ingressUs, dispatchUs, handlerUs, dispatchWaitMs, frames, heap = {}, {}, {}, {}, {}, {}
				egressUs, workSamples = {}, {}
				sendAttempts, physicalSends, logicalActorRecords, resultRecords, payloadBytes = 0, 0, 0, 0, 0
				dispatchCounts, dispatchVisits = {}, {}
				calls, offered, admitted, ingressHandlers = 0, 0, 0, 0
				peakJobs, peakBytes, peakResults, peakResultBytes, maxOthers = 0, 0, 0, 0, 0
				blockedReservations = 0
				epoch = workspace:GetServerTimeNow() + 1
				local startedUnixMs = DateTime.now().UnixTimestampMillis
				local started = os.clock()
				measuring = true
				-- Per-client plan indices are stable for each run.
				phase, replies = tostring(#cases) .. ":Run", {}

				for index, player in players do
					control:FireClient(
						player,
						buffer.fromstring(HttpService:JSONEncode({
							kind = "Run",
							phase = phase,
							mode = mode,
							epoch = epoch,
							index = index,
							clients = clientCount,
						}))
					)
				end

				waitFor(function(): boolean
					return count(replies) == clientCount
				end, "Missing sent reports")

				local sent = 0
				local sentByPlayer: { [Player]: number } = {}

				for player, reply in replies do
					sent += reply.sent
					sentByPlayer[player] = reply.sent
				end

				waitFor(function(): boolean
					local internal: any = runtime

					return offered == sent and pending() == 0 and (internal.Step == nil or calls == admitted)
				end, "Admitted native jobs did not drain")

				phase, replies = tostring(#cases) .. ":Collect", {}

				for _, player in players do
					local accepted = {}

					for id, record in requests[player] do
						local internal: any = runtime

						assert(
							(record.accepted or not record.executed)
								and (internal.Step == nil or record.accepted == record.executed),
							"Admitted job lost or refused job executed"
						)

						if record.executed then
							table.insert(accepted, id)
						end
					end

					table.sort(accepted)

					control:FireClient(
						player,
						buffer.fromstring(
							HttpService:JSONEncode({ kind = "Collect", phase = phase, accepted = accepted })
						)
					)
				end

				waitFor(function(): boolean
					return count(replies) == clientCount
				end, "Result-first delivery did not converge")

				measuring = false
				local clients = {}

				for player, reply in replies do
					local windows: { [number]: { window: number, offered: number, admitted: number } } = {}

					reply.offered, reply.admitted, reply.executed = 0, 0, 0
					reply.planIndex = table.find(players, player)

					for _, record in requests[player] do
						reply.offered += 1
						reply.admitted += if record.accepted then 1 else 0
						reply.executed += if record.executed then 1 else 0

						local current = windows[record.window] or { window = record.window, offered = 0, admitted = 0 }

						windows[record.window] = current
						current.offered += 1
						current.admitted += if record.accepted then 1 else 0
					end

					reply.admissionWindows = {}
					reply.wireOffered = reply.offered
					reply.offered = sentByPlayer[player] + reply.localRefused

					for window = 0, 10 do
						if windows[window] ~= nil then
							table.insert(reply.admissionWindows, windows[window])
						end
					end

					table.insert(clients, reply)
				end

				local planned = 0

				for _, reply in clients do
					planned += reply.offered
				end

				table.insert(cases, {
					mode = mode,
					admissionPolicy = if (runtime :: any).admission ~= nil
						then "ProtectedShared"
						elseif (runtime :: any).Step ~= nil then "GlobalFirstCome"
						else "N9",
					recipients = clientCount,
					actors = clientCount,
					startedUnixMs = startedUnixMs,
					endedUnixMs = DateTime.now().UnixTimestampMillis,
					seconds = os.clock() - started,
					sendAttempts = sendAttempts,
					physicalSends = physicalSends,
					logicalActorRecords = logicalActorRecords,
					resultRecords = resultRecords,
					payloadBytes = payloadBytes,
					egressUs = Scenario.summarize(egressUs),
					offered = planned,
					wireOffered = offered,
					localRefused = planned - offered,
					admitted = admitted,
					executed = calls,
					unexecutedPreEffect = admitted - calls,
					blockedReservations = blockedReservations,
					rejections = rejected,
					handlersOnIngress = ingressHandlers,
					peakPending = peakJobs,
					peakPendingBytes = peakBytes,
					peakResults = peakResults,
					peakResultBytes = peakResultBytes,
					maxOtherDispatchesWhileEligibleHead = maxOthers,
					clients = clients,
					ingressUs = Scenario.summarize(ingressUs),
					dispatchUs = Scenario.summarize(dispatchUs),
					handlerUs = Scenario.summarize(handlerUs),
					dispatchWaitMs = Scenario.summarize(dispatchWaitMs),
					serverHeartbeatMs = Scenario.summarize(frames),
					dispatchesPerPump = Scenario.summarize(dispatchCounts),
					visitsPerPump = Scenario.summarize(dispatchVisits),
					raw = {
						egressUs = egressUs,
						work = workSamples,
						ingressUs = ingressUs,
						dispatchUs = dispatchUs,
						handlerUs = handlerUs,
						dispatchWaitMs = dispatchWaitMs,
						serverHeartbeatMs = frames,
						heapKiB = heap,
						dispatchesPerPump = dispatchCounts,
						visitsPerPump = dispatchVisits,
					},
				})

				-- Keep the following offered workload independent of still-pending
				-- correlations for silently refused requests. Both arms use the
				-- same quiet interval, outside all timed case windows.
				if (mode == "Overload" or mode == "Late") and #cases < #Scenario.modes then
					task.wait(Constants.TIMEOUT_SECONDS + Constants.GRACE_SECONDS + 1)
				else
					task.wait(1.1)
				end
			end

			for _, actor in actors do
				assert(Actors.UnregisterActor(actor))
			end

			table.clear(actors)
			request("Retire")
		end)

		finish(completed, if completed then nil else tostring(failure))
	end)
end
