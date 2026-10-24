--!strict
-- CPU-only experiment in Studio. Fake recipients terminate at a buffer sink.
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

local function measure(population: any, mode: string, actionCount: number, recipients: number, diagnostic: boolean): any
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

	local revisions: { [Player]: { [number]: number } } = {}
	local counts: { [Player]: number } = {}

	for _, player in players do
		revisions[player], counts[player] = {}, 0
	end

	-- Initial baselines are real production work, but outside steady-state timing.
	local baselineEnds = 0
	local baselineSteps = 0

	for _ = 1, 5000 do
		if baselineEnds == population.actors * recipients then
			break
		end

		runtime:Step(Scenario.budget())
		baselineSteps += 1

		for _, delivery in deliveries do
			local records, decodeReason = codec.Decode(delivery.payload)
			assert(records ~= nil, decodeReason)

			for _, record in records do
				if record.kind == "BaselineEnd" then
					assert(revisions[delivery.player][record.handle] == nil, "Duplicate simulated baseline")
					revisions[delivery.player][record.handle] = record.revision
					baselineEnds += 1
				end
			end
		end

		table.clear(deliveries)
		yieldBetweenBatches()
	end

	for _, player in players do
		for _, actor in subjects do
			local handle = runtime:GetHandle(player, actor)
			assert(handle ~= nil and revisions[player][handle] ~= nil, "Incomplete simulated initial baseline")
		end
	end

	table.clear(deliveries)

	local bytes, packets = 0, 0
	local packetSizes: { number } = {}
	local createdSteps: { { number } } = {}
	local queueSteps: { number } = {}
	local initialRevisions: { [Player]: { [number]: number } } = {}

	for _, player in players do
		initialRevisions[player] = table.clone(revisions[player])
	end

	for index = 1, population.actors do
		createdSteps[index] = {}
	end

	local function audit(): ()
		for _, delivery in deliveries do
			local records, decodeReason = codec.Decode(delivery.payload)
			assert(records ~= nil, decodeReason)
			bytes += buffer.len(delivery.payload)
			packets += 1
			table.insert(packetSizes, buffer.len(delivery.payload))

			for _, record in records do
				assert(record.kind == "Commit", "Unexpected synthetic recovery or halt")
				local prior = revisions[delivery.player][record.handle] or 0
				assert(record.revision == prior + 1, "Lost synthetic revision")
				revisions[delivery.player][record.handle] = record.revision

				local generation = record.revision - initialRevisions[delivery.player][record.handle]
				table.insert(queueSteps, delivery.step - createdSteps[record.handle][generation] - 1)

				local ownsActions = actionCount > 0 and record.handle <= math.floor(population.actors * 0.2)
				assert(#record.events == (if ownsActions then 2 else 1), "Lost synthetic event barrier")
				local tagEvents, actionEvents = 0, 0

				for _, event in record.events do
					if event.domainId == "KRF.Tags" then
						assert(
							event.eventId == "Refreshed" and event.payload == "Bench.Tag1",
							"Wrong encoded Tag event"
						)

						tagEvents += 1
					else
						assert(
							event.domainId == "Game.SyntheticActions" and event.payload == generation,
							"Wrong encoded synthetic lifecycle"
						)

						actionEvents += 1
					end
				end

				assert(
					tagEvents == 1 and actionEvents == (if ownsActions then 1 else 0),
					"Duplicate/misattributed events"
				)

				assert(
					#record.patches == (if actionCount == 0 then 1 elseif ownsActions then 3 else 2),
					"Lost grouped domain patch"
				)

				for _, change in record.patches do
					assert(change.patch.kind == "Map" and #change.patch.removed == 0, "Unexpected replacement/removal")
					local entries = 0

					for _, entry in change.patch.entries do
						entries += 1

						if change.domainId == "Game.SyntheticActions" then
							assert(entry.sequenceId == actionCount + generation, "Synthetic Action truth differs")
						elseif change.domainId == "Game.SyntheticResources" then
							assert(
								entry.current == 100 - generation % 100 and entry.anchor == generation,
								"Synthetic Resource truth differs"
							)
						else
							assert(change.domainId == "KRF.Tags" and entry.stackCount == 1, "Tag truth differs")
						end
					end

					assert(entries == 1, "Unexpected broad patch")
				end

				counts[delivery.player] += 1
			end
		end

		table.clear(deliveries)
	end

	local mutationUs: { number } = {}
	local authorityUs: { number } = {}
	local stepUs: { number } = {}
	local tickUs: { number } = {}
	local workSamples: { any } = {}
	local stages: { any } = {}
	local heap: { number } = {}
	local generations = table.create(population.actors, 0)
	local expected = 0
	local plan = Scenario.plan(population.actors, mode)

	-- Each 30 Hz virtual workload tick gives the scheduler two 60 Hz normal-budget Steps. This is
	-- CPU/queue pressure, not a server frame or wall-clock delivery experiment.
	for _, indices in plan do
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
			runtime:Step(Scenario.budget())
			table.insert(stepUs, (os.clock() - beforeStep) * 1e6)
			table.insert(workSamples, Scenario.work(runtime))
		end

		table.insert(tickUs, (os.clock() - tickStart) * 1e6)

		if diagnostic then
			table.insert(stages, Probe.stop())
		end

		table.insert(heap, gcinfo())
		audit()
		yieldBetweenBatches()
	end

	for _ = 1, 2000 do
		local complete = true

		for _, player in players do
			complete = complete and counts[player] == expected
		end

		if complete then
			break
		end

		if diagnostic then
			Probe.start()
		end

		local before = os.clock()
		stepIndex += 1
		runtime:Step(Scenario.budget())
		table.insert(stepUs, (os.clock() - before) * 1e6)
		table.insert(workSamples, Scenario.work(runtime))

		if diagnostic then
			table.insert(stages, Probe.stop())
		end

		audit()
		yieldBetweenBatches()
	end

	assert(commitCount == expected, "Lost synthetic N3 commit")

	for _, player in players do
		assert(counts[player] == expected, "Incomplete simulated fanout")
	end

	for index, actor in subjects do
		assert(publication:GetActorSequence(actor) == generations[index], "Incorrect final synthetic sequence")
	end

	local result = {
		actors = population.actors,
		recipients = recipients,
		mode = mode,
		syntheticActionsLobbyWide = actionCount,
		initialBaselineSteps = baselineSteps,
		simulatedSchedulingHz = 60,
		drainSteps = #stepUs - Scenario.ticks * 2,
		queueWaitSteps = Scenario.summarize(queueSteps),
		diagnostic = diagnostic,
		commits = expected,
		deliveredRecords = expected * recipients,
		payloadBytes = bytes,
		packets = packets,
		packetBytes = Scenario.summarize(packetSizes),
		mutationUs = Scenario.summarize(mutationUs),
		authorityInclusiveUs = Scenario.summarize(authorityUs),
		stepUs = Scenario.summarize(stepUs),
		tickUs = Scenario.summarize(tickUs),
		raw = {
			work = workSamples,
			mutationUs = mutationUs,
			authorityInclusiveUs = authorityUs,
			stepUs = stepUs,
			tickUs = tickUs,
			heapKiB = heap,
			stages = stages,
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
	-- Warm up compilation and VM paths; discard this case.
	measure({ actors = 30, players = 10 }, "Ordinary", 0, 2, false)

	for _, diagnostic in { false, true } do
		if diagnostic then
			Probe.install()
		end

		for _, population in Scenario.populations do
			for _, mode in Scenario.modes do
				for _, actions in { 0, 20, 40 } do
					for _, recipients in { 0, 2, population.players } do
						-- Diagnostics need only the target fanout; keep primary timings separate.
						if not diagnostic or recipients == population.players then
							print("CPU baseline", population.actors, mode, actions, recipients, diagnostic)
							table.insert(cases, measure(population, mode, actions, recipients, diagnostic))
						end
					end
				end
			end
		end
	end

	local encoded = HttpService:JSONEncode({ success = true, cases = cases })
	print("__KRF_NETWORKING_CPU_START__")

	for offset = 1, #encoded, 8000 do
		print(string.sub(encoded, offset, offset + 7999))
		yieldBetweenBatches()
	end

	print("__KRF_NETWORKING_CPU_END__")
end)

Probe.restore()
TagRegistry._resetForTests()
TagController._setAutomaticSteppingEnabledForTests(true)

if not ok then
	error(failure, 0)
end

return nil
