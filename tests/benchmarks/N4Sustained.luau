--!strict
-- Sustained CPU/queue experiment derived from NetworkingBaseline. Fake recipients
-- terminate at a buffer sink; this does not measure native network delivery.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local KRF = ReplicatedStorage.Packages.KRF
local ActorTypes = require(KRF.server.Actor.types)
local TagTypes = require(KRF.server.Tags.types)
local ServerTypes = require(KRF.server.Networking.types)
local ReplicationTypes = require(KRF.server.Replication.types)
local SharedTypes = require(KRF.shared.Networking.types)
local ActorEntity = require(KRF.server.Actor.ActorEntity)
local TagController = require(KRF.server.Tags.TagController)
local TagRegistry: TagTypes.TagRegistry = require(KRF.server.Tags.TagRegistry)

local Domains: ReplicationTypes.InternalReplicationDomainRegistry =
	require(KRF.server.Replication.ReplicationDomainRegistry)

local Publication: ServerTypes.PublicationRuntimeModule = require(KRF.server.Networking.PublicationRuntime)
local Awareness: ServerTypes.ActorAwarenessRuntimeModule = require(KRF.server.Networking.ActorAwarenessRuntime)
local Networking: ServerTypes.ServerNetworking = require(KRF.server.Networking.ServerNetworking)
local Tags = require(KRF.server.Networking.utils.TagsReplication)
local Wire = require(KRF.shared.Networking.ActorStreamCodec)
local Schema: SharedTypes.Schema = require(KRF.shared.Networking.Schema)
local Constants = require(KRF.shared.Networking.utils.ActorProtocolConstants)
local Scenario = require(ReplicatedStorage.NetworkingBaselineScenario)
local Probe = require(ReplicatedStorage.Tests.integration.NetworkingBaseline.Utils.Probe)

-- The plugin runner must return control to Studio. Yields occur only between
-- timed batches; virtual workload time and mutation order remain deterministic.
local lastYield = os.clock()

local function yieldBetweenBatches(): ()
	if os.clock() - lastYield >= 0.05 then
		task.wait()
		lastYield = os.clock()
	end
end

local definitions: { TagTypes.TagDefinition } = {}

for index = 1, 5 do
	local definition: TagTypes.TagDefinition = {
		id = "Bench.Tag" .. index,
		visibility = "ClientVisible",
		duplicateBehavior = "Stack",
		maxStacks = if index == 1 then 1 else 3,
		defaultDuration = 10000,
	}

	table.insert(definitions, definition)
end

local function measure(population: any, recipients: number): any
	local actionCount = 40
	local diagnostic = false
	assert(TagRegistry.Load(definitions))
	local subjects: { ActorTypes.Actor } = {}
	local controllers: { TagTypes.InternalTagController } = {}
	local actionStates: { [ActorTypes.Actor]: any } = {}
	local resourceStates: { [ActorTypes.Actor]: any } = {}
	local actionCallbacks: { [ActorTypes.Actor]: ReplicationTypes.ReplicationDomainOnCommitted } = {}
	local resourceCallbacks: { [ActorTypes.Actor]: ReplicationTypes.ReplicationDomainOnCommitted } = {}
	local tags = Tags.Build(definitions)
	assert(tags ~= nil, "Expected built-in Tags domain")
	local domainDefinitions: { ReplicationTypes.ReplicationDomainDefinition } = { tags }

	local function domain(
		id: string,
		schema: SharedTypes.SchemaDefinition,
		states: any,
		callbacks: any
	): ReplicationTypes.ReplicationDomainDefinition
		local definition: ReplicationTypes.ReplicationDomainDefinition = {
			id = id,
			state = schema,
			events = { { id = "Transition", payload = Schema.U32 } },
			snapshot = function(actor: ActorTypes.Actor): any
				return table.clone(states[actor])
			end,
			observe = function(
				actor: ActorTypes.Actor,
				callback: ReplicationTypes.ReplicationDomainOnCommitted
			): () -> ()
				callbacks[actor] = callback

				return function()
					callbacks[actor] = nil
				end
			end,
		}

		return if diagnostic then Probe.domain(definition) else definition
	end

	if actionCount > 0 then
		table.insert(
			domainDefinitions,
			domain(
				"Game.SyntheticActions",
				Schema.Map(
					Schema.U32,
					Schema.Struct({
						actionId = Schema.Enum({ "Attack", "Guard", "Dash", "Cast" }),
						sequenceId = Schema.U32,
						active = Schema.Boolean,
					}),
					40
				),
				actionStates,
				actionCallbacks
			)
		)

		table.insert(
			domainDefinitions,
			domain(
				"Game.SyntheticResources",
				Schema.Map(
					Schema.Enum({ "Health", "Mana", "Stamina", "Guard", "Rage", "Shield" }),
					Schema.Struct({
						current = Schema.F64,
						min = Schema.F64,
						max = Schema.F64,
						rate = Schema.F64,
						anchor = Schema.F64,
					}),
					6
				),
				resourceStates,
				resourceCallbacks
			)
		)
	end

	local catalog, reason = Domains.Prepare(domainDefinitions)
	assert(catalog ~= nil, reason)
	local protocol, protocolReason = Networking.Prepare(catalog)
	assert(protocol ~= nil, protocolReason)
	local publication = Publication.new(catalog)
	local commitCount = 0

	publication:ObserveCommits(function()
		commitCount += 1
	end)

	for index = 1, population.actors do
		local actor: ActorTypes.Actor = ActorEntity.new()
		actor.enabled = true

		local controller = TagController.new(actor) :: TagTypes.InternalTagController
		assert(actor:SetController("TagController", controller))
		table.insert(subjects, actor)
		table.insert(controllers, controller)

		for tagIndex = 1, 1 + (index - 1) % 5 do
			for _ = 1, (if tagIndex == 1 then 1 else 1 + (index + tagIndex) % 3) do
				assert(controller:AddTag("Bench.Tag" .. tagIndex))
			end
		end

		local actions: any = {}

		local fightingActors = math.floor(population.actors * 0.2)

		local ownedActions = if index <= fightingActors
			then math.floor(actionCount / fightingActors) + (if index <= actionCount % fightingActors then 1 else 0)
			else 0

		for slot = 1, ownedActions do
			actions[slot] = { actionId = "Attack", sequenceId = slot, active = true }
		end

		actionStates[actor] = actions
		resourceStates[actor] = {}

		for _, id in { "Health", "Mana", "Stamina", "Guard", "Rage", "Shield" } do
			resourceStates[actor][id] = { current = 100, min = 0, max = 100, rate = 2, anchor = 0 }
		end

		assert(publication:AttachActor(actor))
		yieldBetweenBatches()
	end

	local readyCallback: ((Player) -> ())? = nil
	local deliveries: { { player: Player, payload: buffer, step: number } } = {}
	local stepIndex = 0
	local players: { Player } = {}
	local schemas: SharedTypes.ActorSchemaCatalog = {}

	for _, definition in catalog.orderedDefinitions do
		schemas[definition.id] = definition.state
	end

	local codec = Wire.Compile(protocol.runtime, schemas)

	local dependencies: ServerTypes.ActorAwarenessDependencies = {
		IsClientReady = function(): boolean
			return true
		end,
		ObserveClientReady = function(callback: (Player) -> ()): () -> ()
			readyCallback = callback

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
			table.insert(deliveries, { player = player, payload = payload, step = stepIndex })

			return true, nil
		end,
		ReportFault = function(fault: ServerTypes.ActorAwarenessFault)
			error(fault.reason, 0)
		end,
	}

	local runtime = Awareness.new(publication, catalog, protocol.runtime, dependencies, {
		maxBaselineBytes = Constants.MAX_BASELINE_BYTES,
		maxChunkBytes = Constants.CHUNK_BYTES,
		maxQueuedBytes = Constants.MAX_QUEUED_BYTES,
		maxEvents = Constants.MAX_EVENTS,
		maxHandle = Constants.MAX_COUNTER,
		maxRevision = Constants.MAX_COUNTER,
	})

	for _ = 1, recipients do
		-- Opaque recipient identities, matching the injected unit-test seam.
		local player: Player = Instance.new("Folder") :: any
		table.insert(players, player)
		assert(readyCallback ~= nil, "Expected N4 readiness subscription")
		readyCallback(player)
		yieldBetweenBatches()
	end

	local identities: { [string]: number } = {}

	for index, actor in subjects do
		identities[actor:GetId()] = index
	end

	local streams: { [Player]: { [number]: any } } = {}

	for _, player in players do
		streams[player] = {}
	end

	local bytes, packets, delivered, replaced, replacements, baselineEnds = 0, 0, 0, 0, 0, 0
	local packetSizes: { number } = {}
	local queueSteps: { number } = {}
	local sentinelSteps: { number } = {}
	local createdSteps: { { number } } = {}

	for index = 1, population.actors do
		createdSteps[index] = {}
	end

	local function audit(): ()
		for _, delivery in deliveries do
			local records, packetReason = codec.Decode(delivery.payload)
			assert(records ~= nil, packetReason)

			if stepIndex > 0 then
				bytes += buffer.len(delivery.payload)
				packets += 1
				table.insert(packetSizes, buffer.len(delivery.payload))
			end

			for _, record in records do
				local known = streams[delivery.player][record.handle]

				if record.kind == "BaselineBegin" then
					if known == nil then
						assert(record.actorId ~= nil and identities[record.actorId] ~= nil, "Unknown identity")
						known = { index = identities[record.actorId], generation = 0, revision = 0, epoch = 0 }
						streams[delivery.player][record.handle] = known
					else
						assert(record.actorId == nil and record.generation > known.epoch, "Invalid replacement")
						replacements += 1
					end

					known.epoch, known.offset = record.generation, 0
					known.body = buffer.create(record.totalBytes)
				elseif record.kind == "BaselineChunk" then
					assert(known ~= nil and known.body ~= nil and record.generation == known.epoch, "Invalid chunk")
					assert(record.offset == known.offset, "Out-of-order chunk")
					buffer.copy(known.body, record.offset, record.bytes)
					known.offset += buffer.len(record.bytes)
				elseif record.kind == "BaselineEnd" then
					assert(known ~= nil and known.body ~= nil and record.generation == known.epoch, "Invalid End")

					assert(
						known.offset == buffer.len(known.body) and record.revision == known.revision + 1,
						"Invalid baseline fence"
					)

					local domains, decodeReason = codec.DecodeBaseline(known.body)
					assert(domains ~= nil, decodeReason)
					local generation = domains["Game.SyntheticResources"].value.Mana.anchor
					assert(generation >= known.generation, "Recovery moved truth backwards")
					replaced += generation - known.generation
					known.generation, known.revision, known.body = generation, record.revision, nil
					baselineEnds += 1
				elseif record.kind == "Commit" then
					assert(
						known ~= nil and known.body == nil and record.revision == known.revision + 1,
						"Lost revision/barrier"
					)

					local generation = known.generation + 1
					local ownsActions = known.index <= math.floor(population.actors * 0.2)
					assert(#record.events == (if ownsActions then 2 else 1), "Lost semantic event")

					for _, event in record.events do
						if event.domainId == "KRF.Tags" then
							assert(event.eventId == "Refreshed" and event.payload == "Bench.Tag1", "Wrong Tag event")
						else
							assert(
								ownsActions
									and event.domainId == "Game.SyntheticActions"
									and event.payload == generation,
								"Reordered synthetic event"
							)
						end
					end

					assert(#record.patches == (if ownsActions then 3 else 2), "Lost grouped domain patch")

					for _, change in record.patches do
						assert(change.patch.kind == "Map" and #change.patch.removed == 0, "Unexpected patch")
						local entries = 0

						for _, entry in change.patch.entries do
							entries += 1

							if change.domainId == "Game.SyntheticResources" then
								assert(
									entry.anchor == generation and entry.current == 100 - generation % 100,
									"Incorrect recovered truth"
								)
							elseif change.domainId == "Game.SyntheticActions" then
								assert(entry.sequenceId == actionCount + generation, "Incorrect Action truth")
							else
								assert(change.domainId == "KRF.Tags" and entry.stackCount == 1, "Incorrect Tag truth")
							end
						end

						assert(entries == 1, "Unexpected broad patch")
					end

					local delay = delivery.step - createdSteps[known.index][generation] - 1
					table.insert(queueSteps, delay)

					if known.index == population.actors then
						table.insert(sentinelSteps, delay)
					end

					known.generation, known.revision = generation, record.revision
					delivered += 1
				else
					error("Unexpected halt/removal")
				end
			end
		end

		table.clear(deliveries)
	end

	local baselineSteps = 0

	while baselineEnds < population.actors * recipients do
		assert(baselineSteps < 5000, "Initial baselines stalled")
		runtime:Step(Constants.STEP_BYTES, Constants.STEP_RECORDS)
		baselineSteps += 1
		audit()
		yieldBetweenBatches()
	end

	local mutationUs: { number } = {}
	local authorityUs: { number } = {}
	local stepUs: { number } = {}
	local tickUs: { number } = {}
	local stages: { any } = {}
	local heap: { number } = {}
	local generations = table.create(population.actors, 0)
	local expected = 0
	local heavy = Scenario.plan(population.actors, "Heavy")
	local plan: { { number } } = {}

	for tick = 1, 3600 do
		local indices: { number } = {}

		if tick <= 900 then
			indices = table.clone(heavy[1 + (tick - 1) % #heavy])

			if tick % 30 == 15 then
				table.insert(indices, population.actors)
			end
		elseif tick <= 1350 then
			for index = 1, population.actors do
				if (tick + index) % 30 == 0 then
					table.insert(indices, index)
				end
			end
		elseif tick % 30 == 15 then
			table.insert(indices, population.actors)
		end

		table.insert(plan, indices)
	end

	local queueSamples: { any } = {}
	local phaseSamples: { any } = {}
	local maxPendingRecords, maxPendingEvents, maxQueuedBytes = 0, 0, 0

	local function sampleQueues(tick: number): ()
		local totalRecords, totalBytes = 0, 0

		-- Read-only instrumentation of private queue status, outside CPU timings.
		for _, connection in (runtime :: any).connections do
			for _, stream in connection.actors do
				local status = stream.scheduler:GetStreamStatus(stream.key)

				assert(
					status.pendingEvents <= Constants.MAX_EVENTS and status.queuedBytes <= Constants.MAX_QUEUED_BYTES,
					"Unbounded queue"
				)

				assert(status.pendingRecords <= Constants.MAX_EVENTS + 1, "Unbounded records")
				maxPendingRecords = math.max(maxPendingRecords, status.pendingRecords)
				maxPendingEvents = math.max(maxPendingEvents, status.pendingEvents)
				maxQueuedBytes = math.max(maxQueuedBytes, status.queuedBytes)
				totalRecords += status.pendingRecords
				totalBytes += status.queuedBytes
			end
		end

		table.insert(queueSamples, {
			tick = tick,
			records = totalRecords,
			bytes = totalBytes,
			replacements = replacements,
			delivered = delivered,
		})
	end

	-- Each 30 Hz virtual workload tick gives the scheduler two 60 Hz normal-budget Steps. This is
	-- CPU/queue pressure, not a server frame or wall-clock delivery experiment.
	for tick, indices in plan do
		if diagnostic then
			Probe.start()
		end

		local tickStart = os.clock()

		for _, index in indices do
			local actor = subjects[index]

			generations[index] += 1

			local generation = generations[index]

			createdSteps[index][generation] = stepIndex

			local authority = 0
			local before = os.clock()

			publication:WithActorCommit(actor, function()
				local authorityStart = os.clock()
				assert(controllers[index]:AddTag("Bench.Tag1", { duration = 10000 + generation * 100 }))

				if actionCount > 0 then
					local ownedActions = #actionStates[actor]

					if ownedActions > 0 then
						local slot = 1 + generation % ownedActions

						actionStates[actor][slot] =
							{ actionId = "Cast", sequenceId = actionCount + generation, active = true }

						actionCallbacks[actor]({ { id = "Transition", payload = generation } })
					end

					resourceStates[actor].Mana =
						{ current = 100 - generation % 100, min = 0, max = 100, rate = 2, anchor = generation }

					resourceCallbacks[actor](nil)
				end

				authority = (os.clock() - authorityStart) * 1e6
			end)

			table.insert(mutationUs, (os.clock() - before) * 1e6)
			table.insert(authorityUs, authority)
			expected += 1
		end

		for _ = 1, 2 do
			stepIndex += 1
			local beforeStep = os.clock()
			runtime:Step(Constants.STEP_BYTES, Constants.STEP_RECORDS)
			table.insert(stepUs, (os.clock() - beforeStep) * 1e6)
		end

		table.insert(tickUs, (os.clock() - tickStart) * 1e6)

		if diagnostic then
			table.insert(stages, Probe.stop())
		end

		table.insert(heap, gcinfo())
		audit()

		if tick % 30 == 0 then
			sampleQueues(tick)
		end

		if tick == 900 or tick == 1350 or tick == 3600 then
			table.insert(phaseSamples, {
				tick = tick,
				delivered = delivered,
				replaced = replaced,
				replacements = replacements,
				packets = packets,
				bytes = bytes,
			})
		end

		yieldBetweenBatches()
	end

	for _ = 1, 5000 do
		local complete = true

		for _, player in players do
			for _, known in streams[player] do
				complete = complete and known.generation == generations[known.index] and known.body == nil
			end
		end

		if complete then
			break
		end

		if diagnostic then
			Probe.start()
		end

		local before = os.clock()
		stepIndex += 1
		runtime:Step(Constants.STEP_BYTES, Constants.STEP_RECORDS)
		table.insert(stepUs, (os.clock() - before) * 1e6)

		if diagnostic then
			table.insert(stages, Probe.stop())
		end

		audit()
		yieldBetweenBatches()
	end

	assert(commitCount == expected, "Lost synthetic N3 commit")

	for _, player in players do
		for _, known in streams[player] do
			assert(known.generation == generations[known.index] and known.body == nil, "Incomplete recovered fanout")
		end
	end

	for index, actor in subjects do
		assert(publication:GetActorSequence(actor) == generations[index], "Incorrect final synthetic sequence")
	end

	assert(delivered + replaced == expected * recipients, "Unaccounted semantic history")
	assert(#sentinelSteps == 120 * recipients, "Quiet stream was lost during overload")
	local fairnessBound = math.ceil(population.actors * recipients * 4 / Constants.STEP_RECORDS) + 60
	assert(Scenario.summarize(sentinelSteps).max <= fairnessBound, "Quiet stream starved")

	if recipients >= 25 then
		assert(replacements > 0, "Sustained load did not exercise recovery")
	end

	assert(#stepUs == #plan * 2, "Quiet recovery required a final drain")
	sampleQueues(3601)

	local result = {
		actors = population.actors,
		recipients = recipients,
		mode = "SustainedHeavyThenRecovery",
		virtualSeconds = 120,
		heavySeconds = 30,
		maxPendingRecords = maxPendingRecords,
		maxPendingEvents = maxPendingEvents,
		maxQueuedBytes = maxQueuedBytes,
		replacements = replacements,
		replacedCommitOccurrences = replaced,
		fairnessBoundSteps = fairnessBound,
		sentinelWaitSteps = Scenario.summarize(sentinelSteps),
		phases = phaseSamples,
		syntheticActionsLobbyWide = actionCount,
		initialBaselineSteps = baselineSteps,
		simulatedSchedulingHz = 60,
		drainSteps = #stepUs - #plan * 2,
		queueWaitSteps = Scenario.summarize(queueSteps),
		diagnostic = diagnostic,
		commits = expected,
		deliveredRecords = delivered,
		payloadBytes = bytes,
		packets = packets,
		packetBytes = Scenario.summarize(packetSizes),
		mutationUs = Scenario.summarize(mutationUs),
		authorityInclusiveUs = Scenario.summarize(authorityUs),
		stepUs = Scenario.summarize(stepUs),
		tickUs = Scenario.summarize(tickUs),
		raw = {
			mutationUs = mutationUs,
			authorityInclusiveUs = authorityUs,
			stepUs = stepUs,
			tickUs = tickUs,
			heapKiB = heap,
			stages = stages,
			queueSamples = queueSamples,
			sentinelWaitSteps = sentinelSteps,
			packetBytes = packetSizes,
			queueWaitSteps = queueSteps,
		},
	}

	runtime:Destroy()
	publication:Destroy()

	for _, controller in controllers do
		controller:Destroy()
	end

	for _, player in players do
		player:Destroy()
	end

	TagRegistry._resetForTests()

	return result
end

TagController._setAutomaticSteppingEnabledForTests(false)

local ok, failure = pcall(function()
	local cases: { any } = {}

	for _, actors in { 75, 90 } do
		for _, recipients in { 2, 10, 25, 30 } do
			print("N4 sustained", actors, recipients)
			table.insert(cases, measure({ actors = actors }, recipients))
		end
	end

	local encoded = HttpService:JSONEncode({ success = true, cases = cases })
	print("__KRF_N4_SUSTAINED_RESULT_START__")

	for offset = 1, #encoded, 8000 do
		print(string.sub(encoded, offset, offset + 7999))
		yieldBetweenBatches()
	end

	print("__KRF_N4_SUSTAINED_RESULT_END__")
end)

Probe.restore()
TagRegistry._resetForTests()
TagController._setAutomaticSteppingEnabledForTests(true)

if not ok then
	error(failure, 0)
end

return nil
