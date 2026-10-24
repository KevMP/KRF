--!strict
-- Real publication, command reservation and egress; opaque recipients, virtual
-- 60-Hz pumps. Native workloads use the same offered-request plan separately.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local KRF = ReplicatedStorage.Packages.KRF
local Types = require(KRF.server.Networking.types)
local ActorTypes = require(KRF.server.Actor.types)
local ReplicationTypes = require(KRF.server.Replication.types)
local SharedTypes = require(KRF.shared.Networking.types)
local Schema = require(KRF.shared.Networking.Schema)
local Domains = require(KRF.server.Replication.ReplicationDomainRegistry)
local Registry = require(KRF.server.Networking.CommandRegistry)
local Networking = require(KRF.server.Networking.ServerNetworking)
local Publication = require(KRF.server.Networking.PublicationRuntime)
local Awareness = require(KRF.server.Networking.ActorAwarenessRuntime)
local Commands = require(KRF.server.Networking.ServerCommandRuntime)
local ActorEntity = require(KRF.server.Actor.ActorEntity)
local CommandCodec = require(KRF.shared.Networking.CommandCodec)
local Constants = require(KRF.shared.Networking.utils.CommandConstants)
local ActorConstants = require(KRF.shared.Networking.utils.ActorProtocolConstants)
local Baseline = require(ReplicatedStorage.NetworkingBaselineScenario)
local Scenario = require(ReplicatedStorage.NetworkingCommandScenario)

local cases: { any } = {}

local function run(recipients: number, mode: string, ticks: number): any
	local workSamples: { any } = {}
	local players: { Player } = {}
	local actors: { ActorTypes.Actor } = {}
	local values: { [ActorTypes.Actor]: number } = {}
	local observers: { [ActorTypes.Actor]: ReplicationTypes.ReplicationDomainOnCommitted } = {}
	local starts: { [Player]: { [number]: number } } = {}
	local admitted: { [Player]: { [number]: boolean } } = {}
	local executed: { [Player]: { [number]: boolean } } = {}
	local counts: { [Player]: number } = {}
	local last: { [Player]: number } = {}
	local delays: { number } = {}
	local resultDelays: { number } = {}
	local ingressUs: { number } = {}
	local dispatchUs: { number } = {}
	local egressUs: { number } = {}
	local handlerUs: { number } = {}
	local perPump: { number } = {}
	local visits: { number } = {}
	local heap: { number } = {}
	local rejections: { [string]: number } = {}
	local now, pump, calls, beforePump, returned, resultCount = 0, 0, 0, 0, 0, 0
	local peakJobs, peakBytes, peakResults, peakResultBytes = 0, 0, 0, 0
	local packets, bytes, ingressHandlers = 0, 0, 0
	local commands: Types.ServerCommandRuntime
	local awareness: Types.ActorAwarenessRuntime
	local codec: SharedTypes.CommandCodec
	local ready: ((Player) -> ())? = nil
	local ownership: { [Player]: ActorTypes.Actor } = {}
	local others: { [Player]: number } = {}
	local maxOthers = 0
	local blockedReservations = 0
	local dispatchOrder: { number } = {}

	local catalog = assert(Domains.Prepare({
		{
			id = "Bench.Commands",
			state = Schema.U32,
			events = { { id = "Changed", payload = Schema.U32 } },
			snapshot = function(actor: ActorTypes.Actor): any
				return values[actor]
			end,
			observe = function(
				actor: ActorTypes.Actor,
				callback: ReplicationTypes.ReplicationDomainOnCommitted
			): () -> ()
				observers[actor] = callback

				return function()
					observers[actor] = nil
				end
			end,
		},
	}))

	local definitions = assert(Registry.Prepare({
		{
			id = "Bench.Command",
			target = "Actor",
			request = Scenario.request,
			result = Scenario.result,
			authorize = function(context: Types.CommandContext): (boolean, string?)
				return context.actor == ownership[context.player],
					if context.actor == ownership[context.player] then nil else "ActorNotOwned"
			end,
			handle = function(context: Types.CommandContext, request: any): Types.CommandHandlerResult
				local started = os.clock()
				local actor = context.actor :: ActorTypes.Actor

				values[actor] += 1
				observers[actor]({ { id = "Changed", payload = request.serial } })
				table.insert(handlerUs, (os.clock() - started) * 1e6)
				assert(context.requestId > (last[context.player] or 0), "Per-connection dispatch reordered")

				if last[context.player] ~= nil then
					assert(
						context:GetPriorOutcome(last[context.player]) ~= nil,
						"Prior outcome missing at next handler"
					)
				end

				last[context.player] = context.requestId
				executed[context.player][context.requestId] = true
				counts[context.player] = (counts[context.player] or 0) + 1
				calls += 1
				table.insert(delays, pump - starts[context.player][context.requestId])
				-- Benchmark-only eligibility inspection; not a permanent diagnostic.
				local internal: any = commands

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

				table.insert(dispatchOrder, table.find(players, context.player) :: number)

				return { accepted = true, result = { serial = request.serial } }
			end,
		},
	}))

	local protocol = assert(Networking.Prepare(catalog, definitions))
	codec = CommandCodec.Compile(protocol.runtime)
	local publication = Publication.new(catalog)

	for _ = 1, 128 do
		local actor = ActorEntity.new(Instance.new("Model"))
		actor.enabled = true
		values[actor] = 0
		table.insert(actors, actor)
		assert(publication:AttachActor(actor))
	end

	local measuring = false

	awareness = Awareness.new(publication, catalog, protocol.runtime, {
		IsClientReady = function(): boolean
			return true
		end,
		ObserveClientReady = function(callback): () -> ()
			ready = callback

			return function() end
		end,
		ObserveClientClosed = function(): () -> ()
			return function() end
		end,
		ObserveAssociationChanged = function(): () -> ()
			return function() end
		end,
		GetPlayerFromCharacter = function(): Player?
			return nil
		end,
		SendReliable = function(player: Player, payload: buffer): (boolean, string?)
			if measuring then
				packets += 1
				bytes += buffer.len(payload)

				if buffer.readu8(payload, 0) == Constants.RESULT_KIND then
					local result = assert(codec.DecodeResult(payload))

					assert(
						result.status == "Accepted" and executed[player][result.requestId],
						"Unexpected result/effect"
					)

					resultCount += 1
					table.insert(resultDelays, pump - starts[player][result.requestId])
				end
			end

			return true, nil
		end,
		ReportFault = function(fault)
			error(fault.reason)
		end,
	}, {
		maxBaselineBytes = ActorConstants.MAX_BASELINE_BYTES,
		maxChunkBytes = ActorConstants.CHUNK_BYTES,
		maxQueuedBytes = ActorConstants.MAX_QUEUED_BYTES,
		maxEvents = ActorConstants.MAX_EVENTS,
		maxHandle = ActorConstants.MAX_COUNTER,
		maxRevision = ActorConstants.MAX_COUNTER,
	})

	for index = 1, recipients do
		local player: Player = Instance.new("Folder") :: any
		table.insert(players, player)
		ownership[player] = actors[index]
		starts[player], admitted[player], executed[player] = {}, {}, {}
		assert(ready ~= nil, "Missing production ready listener")
		ready(player)
	end

	commands = Commands.new(definitions, protocol.runtime, {
		Now = function(): number
			return now
		end,
		ScheduleTimeout = function(): () -> ()
			return function() end
		end,
		IsClientReady = function(): boolean
			return true
		end,
		ObserveClientReady = function(callback: (Player) -> ()): () -> ()
			for _, player in players do
				callback(player)
			end

			return function() end
		end,
		ObserveClientClosed = function(): () -> ()
			return function() end
		end,
		awareness = awareness,
		ReportFault = function(_player, reason)
			error(reason)
		end,
		CloseConnection = function(_player, reason)
			error(reason)
		end,
	})

	local reserve = awareness.ReserveCommandResult

	awareness.ReserveCommandResult = function(
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

	local internal: any = commands
	local outbound: any = awareness

	for _ = 1, 10000 do
		if Baseline.activeCount(outbound) == 0 then
			break
		end

		awareness:Step(Baseline.budget())
	end

	assert(Baseline.activeCount(outbound) == 0, "Join did not drain")

	local function sample(): ()
		local jobs, queuedBytes = 0, 0

		if type(internal._GetPendingForTests) == "function" then
			jobs, queuedBytes = commands:_GetPendingForTests()
		else
			for _, connection in internal.connections do
				jobs += #connection.queue
				queuedBytes += connection.queuedBytes
			end
		end

		peakJobs, peakBytes = math.max(peakJobs, jobs), math.max(peakBytes, queuedBytes)
		local results, resultBytes = 0, 0

		for _, connection in outbound.connections do
			results += #connection.egress.queue
			resultBytes += connection.egress.reservedBytes
		end

		peakResults, peakResultBytes = math.max(peakResults, results), math.max(peakResultBytes, resultBytes)
	end

	local function step(): ()
		pump += 1
		now = pump / 60
		local before = calls
		local started = os.clock()

		if internal.Step ~= nil then
			local _, inspected = commands:Step()
			table.insert(visits, inspected)
		end

		table.insert(dispatchUs, (os.clock() - started) * 1e6)
		table.insert(perPump, calls - before)
		sample()
		started = os.clock()
		awareness:Step(Baseline.budget())
		table.insert(egressUs, (os.clock() - started) * 1e6)
		table.insert(workSamples, Baseline.work(awareness))
		table.insert(heap, gcinfo())
	end

	local ids: { [Player]: number } = {}
	local firstTickAdmitted: { [Player]: number } = {}
	local admissionWindows: { [Player]: { [number]: { offered: number, admitted: number } } } = {}
	local offered = 0
	measuring = true

	local function submit(index: number, tick: number): ()
		local player = players[index]

		ids[player] = (ids[player] or 0) + 1

		local id = ids[player]

		starts[player][id] = pump

		local payload = assert(codec.EncodeRequest({
			commandCode = 0,
			requestId = id,
			targetHandle = awareness:GetHandle(player, actors[index]),
			request = { serial = id, sentAt = now },
		}))

		local before = calls
		local started = os.clock()
		local accepted, reason = commands:Handle(player, payload)
		table.insert(ingressUs, (os.clock() - started) * 1e6)
		ingressHandlers += calls - before
		offered += 1

		if accepted then
			admitted[player][id] = true
			returned += 1

			if tick == 1 then
				firstTickAdmitted[player] = (firstTickAdmitted[player] or 0) + 1
			end
		else
			rejections[reason or "Unknown"] = (rejections[reason or "Unknown"] or 0) + 1
		end

		local windows = admissionWindows[player] or {}

		admissionWindows[player] = windows

		local window = math.floor(now)
		local current = windows[window] or { offered = 0, admitted = 0 }

		windows[window] = current
		current.offered += 1
		current.admitted += if accepted then 1 else 0
		sample()
	end

	for tick = 1, ticks do
		-- Late submits complete noisy bursts before the quiet client, without a
		-- pump. Other plans retain their original interleaved offered order.
		local offers: { number } = {}
		local maximum = 0

		for index = 1, recipients do
			offers[index] = Scenario.offered(tick, index, recipients, mode)
			maximum = math.max(maximum, offers[index])
		end

		if mode == "Late" then
			for index = 1, recipients do
				for _ = 1, offers[index] do
					submit(index, tick)
				end
			end
		else
			for ordinal = 1, maximum do
				for index = 1, recipients do
					if ordinal <= offers[index] then
						submit(index, tick)
					end
				end
			end
		end

		step()
		step()

		if tick % 30 == 0 then
			task.wait()
		end
	end

	beforePump = calls

	for _ = 1, 10000 do
		if Baseline.activeCount(outbound) == 0 and (internal.Step == nil or calls == returned) then
			break
		end

		step()
	end

	assert(resultCount == calls and Baseline.activeCount(outbound) == 0, "Executed results did not converge")

	if internal.Step ~= nil then
		assert(calls == returned, "Admitted jobs did not converge")
		assert(maxOthers < recipients, "Eligible command head starved")
	end

	for player, requests in admitted do
		for id in requests do
			assert(executed[player][id] or internal.Step == nil, "Admitted handler lost")
		end
	end

	local perClient = {}

	for index, player in players do
		local accepted = 0

		for _ in admitted[player] do
			accepted += 1
		end

		local windows = {}

		for window = 0, math.floor(now) do
			local current = if admissionWindows[player] ~= nil then admissionWindows[player][window] else nil

			if current ~= nil then
				table.insert(windows, { window = window, offered = current.offered, admitted = current.admitted })
			end
		end

		table.insert(perClient, {
			client = index,
			offered = ids[player] or 0,
			admitted = accepted,
			executed = counts[player] or 0,
			firstTickAdmitted = firstTickAdmitted[player] or 0,
			admissionWindows = windows,
		})
	end

	if internal.admission ~= nil then
		local quiet = perClient[recipients]

		if mode == "Late" then
			assert(
				quiet.firstTickAdmitted
					>= math.min(8, math.floor(Constants.MAX_GLOBAL_QUEUED_REQUESTS / 4 / recipients)),
				"Quiet client's protected burst opportunity was lost"
			)
		elseif mode == "Pressure" then
			for _, window in quiet.admissionWindows do
				assert(window.admitted > 0, "Quiet client excluded for an entire pressure window")
			end
		end
	end

	local result = {
		mode = mode,
		admissionPolicy = if internal.admission ~= nil
			then "ProtectedShared"
			elseif internal.Step ~= nil then "GlobalFirstCome"
			else "N9",
		recipients = recipients,
		actors = #actors,
		offered = offered,
		admitted = returned,
		executed = calls,
		results = resultCount,
		rejections = rejections,
		handlersOnIngress = ingressHandlers,
		handlersBeforeDrain = beforePump,
		peakPending = peakJobs,
		peakPendingBytes = peakBytes,
		peakResults = peakResults,
		peakResultBytes = peakResultBytes,
		maxOtherDispatchesWhileEligibleHead = maxOthers,
		unexecutedPreEffect = returned - calls,
		blockedReservations = blockedReservations,
		perClient = perClient,
		packets = packets,
		payloadBytes = bytes,
		ingressUs = Scenario.summarize(ingressUs),
		dispatchUs = Scenario.summarize(dispatchUs),
		egressUs = Scenario.summarize(egressUs),
		handlerUs = Scenario.summarize(handlerUs),
		dispatchWaitPumps = Scenario.summarize(delays),
		resultWaitPumps = Scenario.summarize(resultDelays),
		dispatchesPerPump = Scenario.summarize(perPump),
		visitsPerPump = Scenario.summarize(visits),
		raw = {
			work = workSamples,
			ingressUs = ingressUs,
			dispatchUs = dispatchUs,
			egressUs = egressUs,
			handlerUs = handlerUs,
			dispatchWaitPumps = delays,
			resultWaitPumps = resultDelays,
			dispatchesPerPump = perPump,
			visitsPerPump = visits,
			heapKiB = heap,
			dispatchOrder = dispatchOrder,
		},
	}

	commands:Destroy()
	awareness:Destroy()
	publication:Destroy()

	for _, actor in actors do
		if actor.model ~= nil then
			actor.model:Destroy()
		end
	end

	for _, player in players do
		player:Destroy()
	end

	return result
end

local success, reason = pcall(function()
	run(2, "Sustained", 30) -- discarded warmup, identical on both implementations

	for _, recipients in { 2, 8, 32 } do
		for _, mode in Scenario.modes do
			table.insert(cases, run(recipients, mode, Scenario.ticks))
		end
	end
end)

local encoded = HttpService:JSONEncode({
	success = success,
	reason = if success then nil else tostring(reason),
	workloadVersion = Scenario.version,
	profile = "CommandsCPU",
	cases = cases,
})

print("__KRF_NETWORKING_CPU_START__")

for offset = 1, #encoded, 8000 do
	print(string.sub(encoded, offset, offset + 7999))
end

print("__KRF_NETWORKING_CPU_END__")

return nil
