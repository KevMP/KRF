--!strict
-- Non-contractual CPU experiment. Recipients are opaque identities and sends end
-- at a buffer sink. Inspection runs outside timed regions; probes are opt-in.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local KRF = ReplicatedStorage.Packages.KRF
local ActorTypes = require(KRF.server.Actor.types)
local Types = require(KRF.server.Networking.types)
local ReplicationTypes = require(KRF.server.Replication.types)
local SharedTypes = require(KRF.shared.Networking.types)
local ActorEntity = require(KRF.server.Actor.ActorEntity)
local Domains = require(KRF.server.Replication.ReplicationDomainRegistry)
local Publication = require(KRF.server.Networking.PublicationRuntime)
local Awareness = require(KRF.server.Networking.ActorAwarenessRuntime)
local Streams = require(KRF.server.Networking.utils.ActorRecipientStream)
local Scheduler = require(KRF.server.Networking.utils.PublicationScheduler)
local Networking = require(KRF.server.Networking.ServerNetworking)
local Registry = require(KRF.server.Networking.CommandRegistry)
local Commands = require(KRF.server.Networking.ServerCommandRuntime)
local CommandCodec = require(KRF.shared.Networking.CommandCodec)
local Resync = require(KRF.server.Networking.ResyncRuntime)
local ResyncCodec = require(KRF.shared.Networking.utils.ResyncCodec)
local Wire = require(KRF.shared.Networking.ActorStreamCodec)
local Schema: SharedTypes.Schema = require(KRF.shared.Networking.Schema)
local Constants = require(KRF.shared.Networking.utils.ActorProtocolConstants)
local Scenario = require(ReplicatedStorage.NetworkingBaselineScenario)

local cases: { any } = {}
local probes: { [string]: number }? = nil
local restores: { () -> () } = {}

local function install(owner: any, key: string, metric: string): ()
	local original = owner[key]

	owner[key] = function(...: any): ...any
		if probes ~= nil then
			probes[metric] = (probes[metric] or 0) + 1
		end

		return original(...)
	end

	table.insert(restores, function()
		owner[key] = original
	end)
end

local function fixture(actorCount: number, recipientCount: number, maxEvents: number?): any
	local actors: { ActorTypes.Actor } = {}
	local values: { [ActorTypes.Actor]: number } = {}
	local observers: { [ActorTypes.Actor]: ReplicationTypes.ReplicationDomainOnCommitted } = {}
	local deliveries: { any } = {}
	local players: { Player } = {}
	local ready: ((Player) -> ())? = nil
	local commandReady: ((Player) -> ())? = nil
	local callbacks = 0

	local definition: ReplicationTypes.ReplicationDomainDefinition = {
		id = "Bench.Audit",
		state = Schema.Struct({ value = Schema.U32, padding = Schema.String(8192) }),
		events = { { id = "Transition", payload = Schema.U32 } },
		snapshot = function(actor: ActorTypes.Actor): any
			return { value = values[actor], padding = string.rep("x", 8192) }
		end,
		observe = function(actor: ActorTypes.Actor, callback: ReplicationTypes.ReplicationDomainOnCommitted): () -> ()
			observers[actor] = callback

			return function()
				observers[actor] = nil
			end
		end,
	}

	local catalog = assert(Domains.Prepare({ definition }))

	local commandCatalog = assert(Registry.Prepare({
		{
			id = "Bench.Command",
			target = "None",
			request = Schema.U32,
			result = Schema.U32,
			authorize = function(): (boolean, string?)
				return true, nil
			end,
			handle = function(_context: Types.CommandContext, request: any): Types.CommandHandlerResult
				callbacks += 1

				return { accepted = true, result = request }
			end,
		},
	}))

	local protocol = assert(Networking.Prepare(catalog, commandCatalog))
	local publication: Types.PublicationRuntime = Publication.new(catalog)

	for _ = 1, actorCount do
		local actor: ActorTypes.Actor = ActorEntity.new()
		actor.enabled = true
		values[actor] = 0
		table.insert(actors, actor)
		assert(publication:AttachActor(actor))
	end

	local runtime: Types.ActorAwarenessRuntime = Awareness.new(publication, catalog, protocol.runtime, {
		IsClientReady = function(): boolean
			return true
		end,
		ObserveClientReady = function(callback: (Player) -> ()): () -> ()
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
			table.insert(deliveries, { player = player, payload = payload })

			return true, nil
		end,
		ReportFault = function(fault: Types.ActorAwarenessFault): ()
			error(fault.reason, 0)
		end,
	}, {
		maxBaselineBytes = Constants.MAX_BASELINE_BYTES,
		maxChunkBytes = Constants.CHUNK_BYTES,
		maxQueuedBytes = Constants.MAX_QUEUED_BYTES,
		maxEvents = maxEvents or Constants.MAX_EVENTS,
		maxHandle = Constants.MAX_COUNTER,
		maxRevision = Constants.MAX_COUNTER,
	})

	local wire = Wire.Compile(protocol.runtime, { [definition.id] = catalog.definitionsById[definition.id].state })

	local commands: Types.ServerCommandRuntime = Commands.new(commandCatalog, protocol.runtime, {
		Now = function(): number
			return 0 -- One deterministic rate window, independent of machine speed.
		end,
		ScheduleTimeout = function(): () -> ()
			return function() end
		end,
		IsClientReady = function(): boolean
			return true
		end,
		ObserveClientReady = function(callback: (Player) -> ()): () -> ()
			commandReady = callback

			return function() end
		end,
		ObserveClientClosed = function(): () -> ()
			return function() end
		end,
		awareness = runtime,
		ReportFault = function(_player: Player, reason: string): ()
			error(reason, 0)
		end,
		CloseConnection = function(_player: Player, reason: string): ()
			error(reason, 0)
		end,
	})

	local commandCodec = CommandCodec.Compile(protocol.runtime)
	local now = 0

	local resync: Types.ResyncRuntime = Resync.new({
		Now = function(): number
			return now
		end,
		IsClientReady = function(): boolean
			return true
		end,
		ObserveClientClosed = function(): () -> ()
			return function() end
		end,
		RequestReplacementBaseline = function(player: Player, handle: number, reason: string?): (boolean, string?)
			return runtime:RequestReplacementBaseline(player, handle, reason)
		end,
	}, {
		windowSeconds = Constants.RESYNC_WINDOW_SECONDS,
		maxRequestsPerClient = Constants.MAX_RESYNC_PER_CLIENT,
		maxRequestsPerActor = Constants.MAX_RESYNC_PER_ACTOR,
	})

	local function join(): Player
		local player: Player = Instance.new("Folder") :: any
		table.insert(players, player)
		assert(ready ~= nil, "Expected awareness readiness subscription")
		ready(player)

		if commandReady ~= nil then
			commandReady(player)
		end

		return player
	end

	for _ = 1, recipientCount do
		join()
	end

	-- All private-state inspection is benchmark-local and outside timed work.
	local internal: any = runtime

	local function pending(): (number, number, number)
		local bytes, records, baselines = 0, 0, 0

		for _, connection in internal.connections do
			for _, stream in connection.actors do
				local status = stream.scheduler:GetStreamStatus(stream.key)
				bytes += status.queuedBytes
				records += status.pendingRecords

				if stream.baseline ~= nil then
					bytes += buffer.len(stream.baseline.body)
					baselines += 1
				end
			end

			bytes += connection.egress.reservedBytes
			records += #connection.egress.queue
		end

		return bytes, records, baselines
	end

	local function drain(): ()
		local commandState: any = commands

		for _ = 1, 10000 do
			local jobs = if commandState._GetPendingForTests ~= nil then commands:_GetPendingForTests() else 0

			if Scenario.activeCount(internal) == 0 and jobs == 0 then
				return
			end

			if commandState.Step ~= nil then
				commands:Step()
			end

			runtime:Step(Scenario.budget())
			table.clear(deliveries)
		end

		error("Audit drain did not converge")
	end

	return {
		actors = actors,
		players = players,
		runtime = runtime,
		wire = wire,
		commandCodec = commandCodec,
		commands = commands,
		deliveries = deliveries,
		join = join,
		pending = pending,
		drain = drain,
		callbacks = function(): number
			return callbacks
		end,
		mutate = function(index: number, eventful: boolean): ()
			local actor = actors[index]

			values[actor] += 1
			observers[actor](if eventful then { { id = "Transition", payload = values[actor] } } else nil)
		end,
		resync = function(player: Player, handle: number): (boolean, string?)
			local payload = assert(ResyncCodec.Encode(handle))

			return resync:Handle(player, payload)
		end,
		advance = function(): ()
			now += Constants.RESYNC_WINDOW_SECONDS
		end,
		destroy = function(): ()
			resync:Destroy()
			commands:Destroy()
			runtime:Destroy()
			publication:Destroy()

			for _, player in players do
				player:Destroy()
			end
		end,
	}
end

local function scene(actorCount: number, recipients: number, mode: string, diagnostic: boolean): any
	local world = fixture(actorCount, recipients, if mode == "Recovery" then 8 else nil)
	world.drain()
	local finalBytes, finalRecords, finalBaselines = world.pending()
	assert(finalBytes == 0 and finalRecords == 0 and finalBaselines == 0, "Audit retained drained work")
	-- The production workload uses identical deterministic mutations in each pass.
	local counts: { [string]: number } = {}
	probes = if diagnostic then counts else nil
	local pumpUs, mutationUs, waits = {}, {}, {}
	local workSamples, perActorOffered, perActorCompleted = {}, {}, {}

	for index = 1, actorCount do
		perActorOffered[index], perActorCompleted[index] = 0, 0
	end

	local bytes, sends, logical, completed, maxBytes, maxRecords = 0, 0, 0, 0, 0, 0
	local completedByRecipient: { [Player]: { number } } = {}
	local revisions: { [Player]: { [number]: number } } = {}
	local created: { [Player]: { [number]: number } } = {}

	for _, player in world.players do
		revisions[player], created[player] = {}, {}
		completedByRecipient[player] = table.create(actorCount, 0)
	end

	for tick = 1, 120 do
		local started = os.clock()

		if mode == "HotQuiet" then
			world.mutate(1, true)
			perActorOffered[1] += 1

			if tick % 30 == 0 then
				for index = 2, actorCount do
					world.mutate(index, true)
					perActorOffered[index] += 1
				end
			end
		elseif mode == "Hot" or mode == "Recovery" then
			for _ = 1, (if mode == "Recovery" then 16 else 1) do
				world.mutate(1, mode == "Recovery")
				perActorOffered[1] += 1
			end
		elseif mode == "State" or mode == "Events" then
			for index = 1, actorCount do
				world.mutate(index, mode == "Events")
				perActorOffered[index] += 1
			end
		end

		table.insert(mutationUs, (os.clock() - started) * 1e6)
		local queuedBytes, queuedRecords = world.pending()
		maxBytes = math.max(maxBytes, queuedBytes)
		maxRecords = math.max(maxRecords, queuedRecords)

		-- Residence is sampled per stream becoming pending, in virtual pump opportunities.
		for _, player in world.players do
			for index, actor in world.actors do
				local handle = assert(world.runtime:GetHandle(player, actor))

				if
					(
						mode == "State"
						or mode == "Events"
						or (mode == "HotQuiet" and (index == 1 or tick % 30 == 0))
						or (index == 1 and mode ~= "Idle")
					) and created[player][handle] == nil
				then
					created[player][handle] = tick
				end
			end
		end

		started = os.clock()
		world.runtime:Step(Scenario.budget())
		table.insert(pumpUs, (os.clock() - started) * 1e6)
		table.insert(workSamples, Scenario.work(world.runtime))
		local afterBytes, afterRecords = world.pending()
		maxBytes = math.max(maxBytes, afterBytes)
		maxRecords = math.max(maxRecords, afterRecords)

		for _, delivery in world.deliveries do
			bytes += buffer.len(delivery.payload)
			sends += 1
			local records = assert(world.wire.Decode(delivery.payload))
			logical += #records

			for _, record in records do
				if record.kind == "Commit" or record.kind == "BaselineEnd" then
					if mode == "HotQuiet" and record.kind == "Commit" then
						perActorCompleted[record.handle] += 1
						completedByRecipient[delivery.player][record.handle] += 1
					end

					local previous = revisions[delivery.player][record.handle]

					if previous ~= nil then
						assert(record.revision == previous + 1, "Audit revision gap")
					end

					revisions[delivery.player][record.handle] = record.revision

					local enqueued = created[delivery.player][record.handle]

					if enqueued ~= nil then
						table.insert(waits, tick - enqueued)
						created[delivery.player][record.handle] = nil
					end

					if record.kind == "BaselineEnd" then
						completed += 1
					end
				end
			end
		end

		table.clear(world.deliveries)

		if tick % 20 == 0 then
			task.wait()
		end
	end

	probes = nil
	local retainedBytes, retainedRecords, pendingBaselines = world.pending()
	local recoveryCapturesByRecipient: { number } = {}

	if mode == "Recovery" then
		local internal: any = world.runtime

		for _, player in world.players do
			local stream = internal.connections[player].actors[world.actors[1]]
			-- One initial join generation preceded the measured pressure window.
			local captures = stream.generation - 1
			assert(captures > 0, "A recipient received no recovery capture opportunity")
			table.insert(recoveryCapturesByRecipient, captures)
		end
	end

	world.drain()
	local drainedBytes, drainedRecords, drainedBaselines = world.pending()
	assert(drainedBytes == 0 and drainedRecords == 0 and drainedBaselines == 0, "Audit retained drained work")

	if mode == "HotQuiet" then
		for _, vector in completedByRecipient do
			for _, completedRecords in vector do
				assert(
					completedRecords >= 1,
					"Quiet Actor starved for an eligible recipient during sustained hot traffic"
				)
			end
		end
	end

	local result = {
		raw = { pumpUs = pumpUs, waits = waits, work = workSamples },
		perActorOffered = perActorOffered,
		perActorCompleted = perActorCompleted,
		recoveryCapturesByRecipient = recoveryCapturesByRecipient,
		completedByRecipient = (function(): { { number } }
			local vectors = {}

			for _, player in world.players do
				table.insert(vectors, completedByRecipient[player])
			end

			return vectors
		end)(),
		kind = "Scene",
		actors = actorCount,
		recipients = recipients,
		mode = mode,
		diagnostic = diagnostic,
		ticks = 120,
		pumpUs = Scenario.summarize(pumpUs),
		mutationUs = Scenario.summarize(mutationUs),
		queueWaitPumps = Scenario.summarize(waits),
		probes = counts,
		payloadBytes = bytes,
		physicalSends = sends,
		logicalRecords = logical,
		recoveryCompletedDuringLoad = completed,
		peakPendingBytes = maxBytes,
		peakPendingRecords = maxRecords,
		retainedBytesBeforeDrain = retainedBytes,
		retainedRecordsBeforeDrain = retainedRecords,
		pendingBaselinesBeforeDrain = pendingBaselines,
	}

	world.destroy()

	return result
end

local function commandLoad(recipients: number, malformed: boolean): any
	local world = fixture(1, recipients)
	world.drain()
	local elapsed = {}
	local executedBeforeReturn = 0
	local accepted, denied = 0, 0

	for _, player in world.players do
		local started = os.clock()

		for id = 1, 80 do
			local payload = if malformed
				then buffer.create(1)
				else assert(world.commandCodec.EncodeRequest({
					commandCode = 0,
					requestId = id,
					request = id,
				}))

			if malformed then
				buffer.writeu8(payload, 0, 66) -- Malformed packet still routes to command ingress.
			end

			local before = world.callbacks()
			local ok = world.commands:Handle(player, payload)
			executedBeforeReturn += world.callbacks() - before

			if ok then
				accepted += 1
			else
				denied += 1
			end
		end

		table.insert(elapsed, (os.clock() - started) * 1e6)
	end

	local bytes, records = world.pending()

	local result = {
		kind = "Commands",
		recipients = recipients,
		malformed = malformed,
		accepted = accepted,
		denied = denied,
		handlersBeforeReturn = executedBeforeReturn,
		pendingBytes = bytes,
		pendingRecords = records,
		ingressBatchUs = Scenario.summarize(elapsed),
	}

	assert(world.callbacks() == executedBeforeReturn, "Handler escaped synchronous ingress")
	world.drain()
	result.handlersAfterDrain = world.callbacks()
	world.destroy()

	return result
end

local function resultScan(actorCount: number): any
	local world = fixture(actorCount, 1)
	world.drain()
	-- Queue newer Actor work behind a result: every stream fails HasWorkThrough.
	local reservation = assert(world.runtime:ReserveCommandResult(world.players[1], 128))

	assert(
		reservation.Commit(
			assert(world.commandCodec.EncodeResult({ commandCode = 0, requestId = 1, status = "Accepted", result = 1 }))
		)
	)

	for index = 1, actorCount do
		world.mutate(index, false)
	end

	local counts: { [string]: number } = {}
	probes = counts
	local started = os.clock()
	world.runtime:Step(Scenario.budget())
	local elapsed = (os.clock() - started) * 1e6
	probes = nil
	assert(buffer.readu8(world.deliveries[1].payload, 0) == 67, "Result fence regression")
	local result = { kind = "ResultScan", actors = actorCount, probes = counts, pumpUs = elapsed }
	world.destroy()

	return result
end

local function resyncLoad(recipients: number): any
	local world = fixture(64, recipients)
	world.drain()
	local counts: { [string]: number } = {}
	probes = counts
	local accepted, pending, rateLimited = 0, 0, 0
	local started = os.clock()

	for _, player in world.players do
		for _ = 1, 80 do
			local ok, reason = world.resync(player, 1)

			if ok then
				accepted += 1
			elseif reason == "BaselineAlreadyPending" then
				pending += 1
			elseif reason == "ResyncRateLimited" then
				rateLimited += 1
			end
		end
	end

	local elapsed = (os.clock() - started) * 1e6
	probes = nil

	local result = {
		kind = "Resync",
		recipients = recipients,
		accepted = accepted,
		pendingDedupes = pending,
		rateLimited = rateLimited,
		probes = counts,
		ingressUs = elapsed,
	}

	assert(accepted == recipients and counts.captures == recipients, "Pending resync captured duplicate truth")
	world.drain()
	world.destroy()

	return result
end

local function queueExperiment(size: number): any
	local shifting, cursor, scans = {}, {}, {}

	for repetition = 1, 120 do
		local queue = table.create(size, 1)
		local started = os.clock()

		for _ = 1, size do
			assert(table.remove(queue, 1) == 1, "Front removal lost an entry")
		end

		table.insert(shifting, (os.clock() - started) * 1e6)
		queue = table.create(size, 1)
		started = os.clock()

		for index = 1, size do
			assert(queue[index] == 1, "Cursor lost an entry")
			queue[index] = nil
		end

		table.insert(cursor, (os.clock() - started) * 1e6)
		local transfers = table.create(math.min(size, Constants.MAX_PENDING_BASELINES), true)
		local total = 0
		started = os.clock()

		for _ = 1, size do
			for _ in transfers do
				total += 1
			end
		end

		table.insert(scans, (os.clock() - started) * 1e6)
		assert(total == size * #transfers, "Transfer scan skipped an entry")

		if repetition % 20 == 0 then
			task.wait()
		end
	end

	return {
		kind = "QueueAlgorithm",
		size = size,
		shiftsPerDrain = size * (size - 1) / 2,
		frontRemovalUs = Scenario.summarize(shifting),
		cursorUs = Scenario.summarize(cursor),
		pendingTransferScanUs = Scenario.summarize(scans),
	}
end

local function coalescing(width: number, barriers: number): any
	local batches = {}
	local key: Types.PublicationStreamKey = { recipient = {}, actor = {} }
	local initial: { [number]: number } = {}

	for index = 1, width do
		initial[index] = index
	end

	local scheduler: Types.PublicationScheduler = Scheduler.new({
		maxBarriers = 256,
		maxEvents = 256,
		maxQueuedBytes = 262144,
		MeasureRecord = function(): number
			return 64
		end,
	})

	local function commit(sequence: number, eventful: boolean): Types.PublicationFilteredCommit
		return {
			sequence = sequence,
			patches = {
				{ domainId = "Bench.Map", patch = { kind = "Map", entries = { [1] = sequence }, removed = {} } },
			},
			events = if eventful then { { domainId = "Bench.Map", eventId = "Changed", payload = sequence } } else {},
		}
	end

	for _ = 1, 30 do
		scheduler:ResetAfterBaseline(key, { ["Bench.Map"] = { value = initial } })

		for index = 1, barriers do
			assert(scheduler:Enqueue(key, commit(index, true)))
		end

		local started = os.clock()

		for index = 1, 20 do
			assert(scheduler:Enqueue(key, commit(barriers + index, false)))
		end

		table.insert(batches, (os.clock() - started) * 1e6)
		local status = scheduler:GetStreamStatus(key)

		assert(
			status.pendingRecords == barriers + 1 and status.pendingEvents == barriers and not status.needsBaseline,
			"State coalescing changed event barriers or exceeded bounds"
		)

		task.wait()
	end

	scheduler:Destroy()

	return {
		kind = "Coalescing",
		width = width,
		barriers = barriers,
		writesPerBatch = 20,
		batchUs = Scenario.summarize(batches),
		measurement = "scheduler only; constant 64-byte estimator; no codec",
	}
end

local success, failure = pcall(function()
	-- Warm the VM/schema/compiler and discard the pilot.
	scene(16, 1, "State", false)

	for _, diagnostic in { false, true } do
		if diagnostic then
			install(Streams, "Prepare", "prepares")
			install(Streams, "HasWork", "eligibilityChecks")
			install(Streams, "HasWorkThrough", "orderChecks")
			install(Streams, "Capture", "captures")
			install(Publication, "CaptureBaseline", "baselineTruthReads")
			install(Scheduler, "Enqueue", "enqueues")
		end

		for _, actors in { 1, 16, 64, 128 } do
			for _, recipients in { 1, 8, 32 } do
				for _, mode in { "Idle", "Hot", "State", "Events", "HotQuiet" } do
					table.insert(cases, scene(actors, recipients, mode, diagnostic))
				end
			end
		end
	end

	for _, recipients in { 1, 8, 32 } do
		table.insert(cases, scene(1, recipients, "Recovery", true))
		table.insert(cases, commandLoad(recipients, false))
		table.insert(cases, commandLoad(recipients, true))
		table.insert(cases, resyncLoad(recipients))
	end

	for _, size in { 1, 16, 64, 128, 1024 } do
		table.insert(cases, resultScan(size))
		table.insert(cases, queueExperiment(size))
	end

	for _, width in { 16, 128, 512 } do
		for _, barriers in { 0, 8, 64 } do
			table.insert(cases, coalescing(width, barriers))
		end
	end
end)

probes = nil

for index = #restores, 1, -1 do
	restores[index]()
end

local encoded = HttpService:JSONEncode({
	success = success,
	reason = if success then nil else tostring(failure),
	workloadVersion = 1,
	pattern = "fixed ascending actors; 120 pumps",
	cases = cases,
})

print("__KRF_NETWORKING_CPU_START__")

for offset = 1, #encoded, 8000 do
	print(string.sub(encoded, offset, offset + 7999))
end

print("__KRF_NETWORKING_CPU_END__")

if not success then
	error(failure, 0)
end

return nil
