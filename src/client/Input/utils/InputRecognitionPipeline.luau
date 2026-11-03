--!strict
local Types = require(script.Parent.Parent.types)
local Constants = require(script.Parent.InputConstants)
local Validation = require(script.Parent.InputRecognitionValidation)
local Value = require(script.Parent.InputValue)
local Gesture = require(script.Parent.InputGestureRecognition)
local Custom = require(script.Parent.InputCustomRecognition)
local Sequences = require(script.Parent.InputSequenceRecognition)

export type Plan = {
	gesture: Gesture.Plan,
	catalog: Types.RecognitionCatalog?,
	generation: number,
}

export type Options = {
	Now: () -> number,
	Scheduler: Types.GestureScheduler,
	RunTimer: (() -> ()) -> (),
	DeliverGroup: (Types.GestureDispatchGroup, Types.GestureEvent?) -> (),
	DeliverEnvelope: (Types.InputCandidateEnvelope) -> (),
	NotifySequence: (Types.SequenceMatchEvent) -> (),
	NotifyCustom: (Types.CustomRecognitionEvent) -> (),
	IsEpochActive: (string, number, number) -> boolean,
	Report: (string) -> (),
}

export type Owner = {
	Prepare: (Types.InputGraphSnapshot) -> Plan,
	Commit: (Plan, { [string]: string }) -> (),
	Before: (Types.PrimitiveOccurrence) -> (),
	Accept: (Types.PrimitiveOccurrence) -> (),
	Finish: (Types.PrimitiveOccurrence?) -> (),
	Get: (string) -> { [Types.GestureKind]: Types.GestureSnapshot }?,
	GetSequence: (string) -> Types.SequenceSnapshot?,
	GetRecognizer: (string) -> Types.RecognizerSnapshot?,
	Revision: () -> number,
	Reset: ({ string }?) -> (),
	Destroy: () -> (),
}

type Frame = {
	root: Types.PrimitiveOccurrence?,
	cause: number?,
	candidates: { Types.RecognitionCandidate },
	tokens: { Types.RecognitionToken },
	customEvents: { Types.CustomRecognitionEvent },
	policy: Types.DoubleTapArbitration?,
}

type GestureEmission = { group: Types.GestureDispatchGroup, event: Types.GestureEvent? }

local Pipeline = {}

function Pipeline.new(options: Options): Owner
	local tokenOrdinal: number = 0
	local occurrenceOrdinal: number = 0
	local resultOrdinal: number = 0
	local generation: number = 0
	local revision: number = 0
	local previousCatalog: Types.RecognitionCatalog? = nil
	local emissions: { GestureEmission } = {}
	local current: Frame? = nil
	local custom: Custom.Owner
	local sequences: Sequences.Owner

	local function changed(): ()
		revision += 1
	end

	local function schedule(deadline: number, callback: () -> ()): () -> ()
		return options.Scheduler.Schedule(deadline, function(): ()
			options.RunTimer(callback)
		end)
	end

	local function token(key: string, cause: number?): Types.RecognitionToken
		tokenOrdinal += 1

		return table.freeze({
			key = key,
			ordinal = tokenOrdinal,
			timestamp = options.Now(),
			causeRootInputOrdinal = cause,
		})
	end

	local function frame(root: Types.PrimitiveOccurrence?, cause: number?): Frame
		-- Ordinals are allocated when an envelope is finalized. A mismatch may
		-- first emit older pending prefixes before this root is finalized.
		return { root = root, cause = cause, candidates = {}, tokens = {}, customEvents = {} }
	end

	local function holdOwner(active: Frame): Types.RecognitionHoldOwner?
		local root: Types.PrimitiveOccurrence? = active.root

		if
			root == nil
			or root.event.kind ~= "Pressed"
			or root.pressEpochId == nil
			or not options.IsEpochActive(root.event.inputId, root.pressEpochId, root.generation)
		then
			return nil
		end

		return table.freeze({
			inputId = root.event.inputId,
			inputGeneration = root.generation,
			pressEpochId = root.pressEpochId,
			isActiveAfterCommit = true,
		})
	end

	local function deliver(active: Frame): ()
		assert(#active.candidates <= Constants.MAX_CANDIDATES_PER_OCCURRENCE, "InputCandidateLimitExceeded")
		occurrenceOrdinal += 1
		local root: Types.PrimitiveOccurrence? = active.root
		local candidates: { Types.RecognitionCandidate } = {}
		local customLane: { Types.CustomRecognitionCandidate } = {}
		local sequenceLane: { Types.SequenceRecognitionCandidate } = {}

		for _, candidate: Types.RecognitionCandidate in active.candidates do
			if candidate.kind == "Input" then
				table.insert(candidates, candidate)
			elseif candidate.kind == "Custom" then
				table.insert(customLane, candidate)
			else
				table.insert(sequenceLane, candidate)
			end
		end

		table.sort(
			customLane,
			function(left: Types.CustomRecognitionCandidate, right: Types.CustomRecognitionCandidate): boolean
				return left.recognizerId < right.recognizerId
			end
		)

		table.sort(
			sequenceLane,
			function(left: Types.SequenceRecognitionCandidate, right: Types.SequenceRecognitionCandidate): boolean
				return left.sequenceId < right.sequenceId
			end
		)

		for _, candidate in customLane do
			table.insert(candidates, candidate)
		end

		for _, candidate in sequenceLane do
			table.insert(candidates, candidate)
		end

		table.freeze(candidates)

		if root ~= nil then
			options.DeliverEnvelope(table.freeze({
				kind = "Root" :: "Root",
				occurrenceOrdinal = occurrenceOrdinal,
				timestamp = options.Now(),
				inputGeneration = generation,
				rootInputOrdinal = root.event.ordinal,
				rootInputId = root.event.inputId,
				rootContextId = root.event.contextId,
				rootInputEpochId = root.pressEpochId,
				isRootEpochActiveAfterCommit = root.pressEpochId ~= nil
					and options.IsEpochActive(root.event.inputId, root.pressEpochId, root.generation),
				lifecycleDelivered = true,
				candidates = candidates,
				inputPolicy = active.policy,
			}))
		else
			options.DeliverEnvelope(table.freeze({
				kind = "Deferred" :: "Deferred",
				occurrenceOrdinal = occurrenceOrdinal,
				timestamp = options.Now(),
				inputGeneration = generation,
				causeRootInputOrdinal = active.cause,
				candidates = candidates,
				inputPolicy = active.policy,
			}))
		end

		for _, event: Types.CustomRecognitionEvent in active.customEvents do
			options.NotifyCustom(event)
		end
	end

	local function emitSequences(matches: { Sequences.Match }, immediate: boolean): ()
		if not immediate then
			local byEnd: { [number]: { Sequences.Match } } = {}
			local endings: { number } = {}

			for _, match: Sequences.Match in matches do
				if byEnd[match.token.ordinal] == nil then
					byEnd[match.token.ordinal] = {}
					table.insert(endings, match.token.ordinal)
				end

				table.insert(byEnd[match.token.ordinal], match)
			end

			if #endings > 1 then
				table.sort(endings)

				for _, ending: number in endings do
					emitSequences(byEnd[ending], false)
				end

				return
			end
		end

		table.sort(matches, function(left: Sequences.Match, right: Sequences.Match): boolean
			return left.id < right.id or (left.id == right.id and left.token.ordinal < right.token.ordinal)
		end)

		local active: Frame = if immediate and current ~= nil
			then current
			else frame(nil, matches[1].token.causeRootInputOrdinal)

		for _, match: Sequences.Match in matches do
			local snapshot: Types.SequenceSnapshot? = sequences.Get(match.id)

			if snapshot == nil then
				continue
			end

			resultOrdinal += 1

			local event: Types.SequenceMatchEvent = table.freeze({
				sequenceId = match.id,
				sourceId = snapshot.sourceId,
				recognizedAt = match.recognizedAt,
				timestamp = options.Now(),
				ordinal = resultOrdinal,
				matchedStepCount = #snapshot.definition.steps,
				triggerTokenOrdinal = match.token.ordinal,
			})

			table.insert(
				active.candidates,
				table.freeze({
					kind = "Sequence" :: "Sequence",
					sequenceId = match.id,
					recognitionOrdinal = event.ordinal,
					matchedStepCount = event.matchedStepCount,
					immediate = active.root ~= nil,
					rootInputOrdinal = if active.root ~= nil then active.root.event.ordinal else nil,
					holdOwner = holdOwner(active),
				})
			)

			options.NotifySequence(event)
		end

		if active ~= current and #active.candidates > 0 then
			deliver(active)
		end
	end

	local function emitCustom(id: string, match: Types.CustomMatch, cause: number?, trigger: number?): ()
		local previous: Frame? = current
		local active: Frame = current or frame(nil, cause)
		current = active
		local snapshot: Types.RecognizerSnapshot = assert(custom.Get(id), "Expected custom recognition owner")
		resultOrdinal += 1

		local event: Types.CustomRecognitionEvent = table.freeze({
			recognizerId = id,
			sourceId = snapshot.sourceId,
			timestamp = options.Now(),
			ordinal = resultOrdinal,
			triggerTokenOrdinal = trigger,
			metadata = match.metadata,
		})

		table.insert(
			active.candidates,
			table.freeze({
				kind = "Custom" :: "Custom",
				recognizerId = id,
				recognitionOrdinal = event.ordinal,
				immediate = active.root ~= nil,
				rootInputOrdinal = if active.root ~= nil then active.root.event.ordinal else nil,
				holdOwner = holdOwner(active),
			})
		)

		table.insert(active.tokens, token(Validation.CustomKey(id), cause))
		table.insert(active.customEvents, event)

		if previous == nil then
			sequences.Before()
			sequences.Accept(active.tokens)
			deliver(active)
		end

		current = previous
	end

	sequences = Sequences.new({ Now = options.Now, Schedule = schedule, Emit = emitSequences, Changed = changed })

	custom = Custom.new({
		Now = options.Now,
		Schedule = schedule,
		Emit = emitCustom,
		Changed = changed,
		Report = options.Report,
		Fault = function(id: string): ()
			sequences.Block(id, true)
			local active: Frame? = current

			if active == nil then
				return
			end

			for position: number = #active.candidates, 1, -1 do
				local candidate: Types.RecognitionCandidate = active.candidates[position]

				if candidate.kind == "Custom" and candidate.recognizerId == id then
					table.remove(active.candidates, position)
				end
			end

			for position: number = #active.tokens, 1, -1 do
				if active.tokens[position].key == Validation.CustomKey(id) then
					table.remove(active.tokens, position)
				end
			end

			for position: number = #active.customEvents, 1, -1 do
				if active.customEvents[position].recognizerId == id then
					table.remove(active.customEvents, position)
				end
			end
		end,
	})

	local gesture: Gesture.Owner = Gesture.new({
		Now = options.Now,
		Scheduler = options.Scheduler,
		RunTimer = options.RunTimer,
		Deliver = function(group: Types.GestureDispatchGroup, event: Types.GestureEvent?): ()
			options.DeliverGroup(group, event)
			table.insert(emissions, { group = group, event = event })
		end,
	})

	local function finish(root: Types.PrimitiveOccurrence?, pending: { GestureEmission }): ()
		if root ~= nil then
			local sameRoot: { GestureEmission } = {}

			for _, emission: GestureEmission in pending do
				if
					emission.event ~= nil
					and emission.event.gesture == "Tap"
					and emission.group.policy == "DeferredTap"
				then
					finish(nil, { emission })
				else
					table.insert(sameRoot, emission)
				end
			end

			pending = sameRoot
		end

		custom.Before()
		sequences.Before()

		local cause: number? = if root ~= nil
			then root.event.ordinal
			else if pending[1] ~= nil then pending[1].group.triggerInputOrdinal else nil

		if root == nil and #pending == 0 then
			return
		end

		if root ~= nil and root.event.kind == "Cancelled" then
			sequences.Reset({ root.event.inputId })
		end

		local active: Frame = frame(root, cause)
		current = active
		local watchedEvents: { { event: Types.RecognizerEvent, token: Types.RecognitionToken } } = {}

		if root ~= nil then
			local primitive: Types.RecognitionToken =
				token(Validation.InputKey(root.event.inputId, root.event.kind), root.event.ordinal)

			table.insert(active.tokens, primitive)

			local watched: { event: Types.RecognizerEvent, token: Types.RecognitionToken } =
				{ event = root.event, token = primitive }

			table.insert(watchedEvents, watched)
		end

		for _, emission: GestureEmission in pending do
			active.policy = emission.group.policy or active.policy

			for _, candidate: Types.GestureCandidate in emission.group.candidates do
				table.insert(
					active.candidates,
					table.freeze({
						kind = "Input" :: "Input",
						inputId = candidate.inputId,
						gesture = candidate.key :: "Pressed" | Types.GestureKind,
						recognitionOrdinal = if emission.event ~= nil
								and candidate.key == emission.event.gesture
							then emission.event.ordinal
							else candidate.rootInputOrdinal,
						pressEpochId = candidate.pressEpochId,
						routeEligible = candidate.routeEligible,
					})
				)
			end

			local event: Types.GestureEvent? = emission.event

			if event ~= nil then
				local recognized: Types.RecognitionToken =
					token(Validation.InputKey(event.inputId, event.gesture), event.triggerInputOrdinal)

				table.insert(active.tokens, recognized)

				local normalized = table.clone(event) :: any
				normalized.kind = "Gesture"

				table.insert(
					watchedEvents,
					{ event = table.freeze(normalized) :: Types.RecognizerEvent, token = recognized }
				)
			end
		end

		-- The finalized I2 lane is authoritative for primitive candidates.
		-- A fresh emission identity also deduplicates primitive and I2 callback
		-- output before the (separate) public counters are assigned.
		revision += 1
		local identity: number = revision

		for _, watched in watchedEvents do
			custom.Accept(watched.event, watched.token.key, identity, watched.token)
		end

		sequences.Accept(active.tokens)
		deliver(active)
		current = nil
	end

	return {
		Prepare = function(graph: Types.InputGraphSnapshot): Plan
			return {
				gesture = gesture.Prepare(graph),
				catalog = graph.recognition,
				generation = graph.generation,
			}
		end,
		Commit = function(plan: Plan, invalidated: { [string]: string }): ()
			local changedDependencies: { [string]: boolean } = {}

			local previousGraph: Types.RecognitionCatalog? = previousCatalog

			if plan.catalog ~= nil then
				for id, dependencies in plan.catalog.recognizerDependencies do
					local previous: { [string]: unknown }? = if previousGraph ~= nil
						then previousGraph.recognizerDependencies[id]
						else nil

					changedDependencies[id] = not Value.Equal(previous, dependencies)
				end
			end

			gesture.Commit(plan.gesture, invalidated)
			sequences.Commit(plan.catalog, invalidated)
			custom.Commit(plan.catalog, invalidated, changedDependencies)

			if plan.catalog ~= nil then
				for id in plan.catalog.recognizers do
					sequences.Block(id, assert(custom.Get(id), "Expected recognizer").faulted)
				end
			end

			generation = plan.generation
			previousCatalog = plan.catalog
		end,
		Before = gesture.Before,
		Accept = gesture.Accept,
		Finish = function(root: Types.PrimitiveOccurrence?): ()
			local pending: { GestureEmission } = emissions
			emissions = {}
			finish(root, pending)
		end,
		Get = gesture.Get,
		GetSequence = sequences.Get,
		GetRecognizer = custom.Get,
		Revision = function(): number
			return revision + gesture.Revision()
		end,
		Reset = function(inputIds: { string }?): ()
			changed()
			gesture.Reset(inputIds)
			custom.Reset(inputIds)
			sequences.Reset(inputIds)
		end,
		Destroy = function(): ()
			gesture.Destroy()
			custom.Destroy()
			sequences.Destroy()
			table.clear(emissions)
			previousCatalog = nil
		end,
	}
end

return Pipeline
