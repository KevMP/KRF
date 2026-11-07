--!strict
local Types = require(script.Parent.Parent.types)
local Constants = require(script.Parent.InputConstants)
local Value = require(script.Parent.InputValue)
local Observers = require(script.Parent.Parent.Parent.Parent.shared.Signal.PrivateObservers)
local Epochs = require(script.Parent.InputEpochs)
local MutationGate = require(script.Parent.InputMutationGate)
local RecognitionPipeline = require(script.Parent.InputRecognitionPipeline)
local GestureScheduler = require(script.Parent.InputGestureScheduler)

type PrimitiveObserver = (Types.PrimitiveOccurrence) -> ()
type PhasedObserver = { phase: Types.ObserverPhase, callback: PrimitiveObserver }
type EnvelopeObserver = { callback: (Types.InputCandidateEnvelope) -> (), hasDemand: (() -> boolean)? }

type NotificationBatch = {
	gestures: { Types.GestureEvent },
	sequences: { Types.SequenceMatchEvent },
	customs: { Types.CustomRecognitionEvent },
}

export type Options = {
	Now: () -> number,
	Publish: (Types.SemanticInputEvent) -> (),
	PublishGesture: ((Types.GestureEvent) -> ())?,
	PublishSequence: ((Types.SequenceMatchEvent) -> ())?,
	PublishRecognizer: ((Types.CustomRecognitionEvent) -> ())?,
	IsEpochActive: (string, number, number) -> boolean,
	Scheduler: Types.GestureScheduler?,
	ReportFault: (string) -> (),
}

export type Owner = {
	IsPublishing: () -> boolean,
	Recognition: RecognitionPipeline.Owner,
	Deliver: (input: Types.InputSnapshot, transition: Epochs.Transition, deferred: { Types.SemanticInputEvent }?) -> (),
	PublishInput: (event: Types.SemanticInputEvent) -> (),
	ObservePrimitive: (phase: Types.ObserverPhase, callback: PrimitiveObserver) -> () -> (),
	ObserveGroups: (callback: (Types.GestureDispatchGroup) -> ()) -> () -> (),
	ObserveEnvelopes: (callback: (Types.InputCandidateEnvelope) -> (), hasDemand: (() -> boolean)?) -> () -> (),
	Destroy: () -> (),
}

local Dispatch = {}

local function hasDemand(observer: EnvelopeObserver): boolean
	return observer.hasDemand == nil or observer.hasDemand()
end

-- Owns occurrence stamping and the private-before-public delivery sequence.
function Dispatch.new(options: Options, gate: MutationGate.Owner, onFault: () -> ()): Owner
	local ordinal: number = 0
	local timestamp: number = 0
	local publishingDepth: number = -1
	local notifications: NotificationBatch? = nil
	local timerCallbacks: { () -> () } = {}
	local timersQueued: boolean = false
	local recognition: RecognitionPipeline.Owner
	local report: (string) -> () = options.ReportFault

	local primitives: Observers.Registry<PhasedObserver> = Observers.new(
		Constants.MAX_PRIMITIVE_OBSERVERS,
		"InputObserverLimitExceeded"
	) :: Observers.Registry<PhasedObserver>

	local dispatchGroups: Observers.Registry<(Types.GestureDispatchGroup) -> ()> = Observers.new(
		Constants.MAX_GESTURE_OBSERVERS,
		"InputGestureObserverLimitExceeded"
	) :: Observers.Registry<
		(Types.GestureDispatchGroup) -> ()
	>

	-- I3 owns finalized envelope production; registration/teardown is ready here.
	local envelopes: Observers.Registry<EnvelopeObserver> = Observers.new(
		Constants.MAX_CANDIDATE_OBSERVERS,
		"InputCandidateObserverLimitExceeded"
	) :: Observers.Registry<EnvelopeObserver>

	local function publish<Event>(publisher: ((Event) -> ())?, event: Event): ()
		if publisher == nil then
			return
		end

		local previousDepth: number = publishingDepth
		publishingDepth = gate.Depth()
		local success: boolean, reason: any = pcall(publisher, event)
		publishingDepth = previousDepth

		if not success then
			report(tostring(reason))
		end
	end

	local function publishInput(event: Types.SemanticInputEvent): ()
		publish(options.Publish, event)
	end

	local function readTime(): number
		local now: number = options.Now()

		if Value.IsFinite(now) then
			timestamp = math.max(timestamp, now)
		end

		return timestamp
	end

	local function publishNotifications(batch: NotificationBatch): ()
		for _, event: Types.GestureEvent in batch.gestures do
			if gate.IsTerminal() then
				break
			end

			publish(options.PublishGesture, event)
		end

		-- Both lanes share one ordinal counter and each is already ascending.
		local customIndex: number = 1
		local sequenceIndex: number = 1

		while not gate.IsTerminal() do
			local custom: Types.CustomRecognitionEvent? = batch.customs[customIndex]
			local sequence: Types.SequenceMatchEvent? = batch.sequences[sequenceIndex]

			if custom ~= nil and (sequence == nil or custom.ordinal < sequence.ordinal) then
				customIndex += 1
				publish(options.PublishRecognizer, custom)
			elseif sequence ~= nil then
				sequenceIndex += 1
				publish(options.PublishSequence, sequence)
			else
				break
			end
		end
	end

	local function deliverEnvelope(envelope: Types.InputCandidateEnvelope): ()
		for _, entry in envelopes.Snapshot(hasDemand) do
			if gate.IsTerminal() then
				break
			end

			if entry.active then
				local success: boolean, reason: string? = Observers.Run(entry.callback.callback, envelope)

				if not success then
					report("InputCandidateObserver" .. (reason or "Failed"))
					break
				end
			end
		end
	end

	local function deliverGroup(group: Types.GestureDispatchGroup, event: Types.GestureEvent?): ()
		for _, entry in dispatchGroups.Snapshot() do
			if gate.IsTerminal() then
				break
			end

			if entry.active then
				local success: boolean, reason: string? = Observers.Run(entry.callback, group)

				if not success then
					report("InputGestureObserver" .. (reason or "Failed"))
				end
			end
		end

		if event ~= nil and notifications ~= nil then
			table.insert(notifications.gestures, event)
		end
	end

	local runTimer: (callback: () -> ()) -> ()

	runTimer = function(callback: () -> ()): ()
		if not gate.CanDispatch() then
			return
		end

		if gate.IsBusy() or gate.IsValidating() then
			assert(#timerCallbacks < Constants.MAX_GESTURE_DEADLINES, "InputGestureDeadlineLimitExceeded")
			table.insert(timerCallbacks, callback)

			if not timersQueued then
				timersQueued = true

				local accepted: boolean = gate.Queue(function(): ()
					timersQueued = false
					local callbacks: { () -> () } = timerCallbacks
					timerCallbacks = {}

					for _, pendingCallback in callbacks do
						runTimer(pendingCallback)
					end
				end)

				if not accepted then
					onFault()
				end
			end

			return
		end

		gate.EnterDispatch()
		local batch: NotificationBatch = { gestures = {}, sequences = {}, customs = {} }
		local previousNotifications: NotificationBatch? = notifications
		notifications = batch

		local success: boolean, reason: any = pcall(function(): ()
			callback()
			recognition.Finish(nil)
		end)

		notifications = previousNotifications

		if not success then
			report(tostring(reason))
			onFault()
		else
			publishNotifications(batch)
		end

		gate.LeaveDispatch()
		gate.Flush()
	end

	recognition = RecognitionPipeline.new({
		Now = readTime,
		Scheduler = options.Scheduler or GestureScheduler.new(readTime, report),
		RunTimer = runTimer,
		DeliverGroup = deliverGroup,
		DeliverEnvelope = deliverEnvelope,
		HasEnvelopeObservers = function(): boolean
			return not envelopes.IsEmpty(hasDemand)
		end,
		IsEpochActive = options.IsEpochActive,
		Report = report,
		NotifySequence = function(event: Types.SequenceMatchEvent): ()
			if notifications ~= nil then
				table.insert(notifications.sequences, event)
			end
		end,
		NotifyCustom = function(event: Types.CustomRecognitionEvent): ()
			if notifications ~= nil then
				table.insert(notifications.customs, event)
			end
		end,
	})

	local function deliver(
		input: Types.InputSnapshot,
		transition: Epochs.Transition,
		deferred: { Types.SemanticInputEvent }?
	): ()
		if gate.IsTerminal() then
			return
		end

		ordinal += 1
		readTime()

		local event: Types.SemanticInputEvent

		if transition.kind == "Cancelled" then
			event = table.freeze({
				kind = "Cancelled" :: "Cancelled",
				inputId = input.id,
				contextId = input.contextId,
				inputType = input.inputType,
				timestamp = timestamp,
				ordinal = ordinal,
				reason = transition.reason or "InputInvalidated",
			})
		elseif transition.kind == "Pressed" or transition.kind == "Released" then
			event = table.freeze({
				kind = transition.kind,
				inputId = input.id,
				contextId = input.contextId,
				inputType = input.inputType,
				timestamp = timestamp,
				ordinal = ordinal,
				value = transition.value :: boolean,
			})
		else
			event = table.freeze({
				kind = "StateChanged" :: "StateChanged",
				inputId = input.id,
				contextId = input.contextId,
				inputType = input.inputType,
				timestamp = timestamp,
				ordinal = ordinal,
				value = transition.value :: number | Vector2 | Vector3,
			})
		end

		local occurrence: Types.PrimitiveOccurrence =
			table.freeze({ event = event, generation = transition.generation, pressEpochId = transition.epochId })

		gate.EnterDispatch()
		local batch: NotificationBatch = { gestures = {}, sequences = {}, customs = {} }
		local previousNotifications: NotificationBatch? = notifications
		notifications = batch
		local interpreted: boolean = pcall(recognition.Before, occurrence)

		if not interpreted then
			onFault()
		end

		for _, phase: Types.ObserverPhase in { "Interpretation", "Arbitration", "Routing" } do
			for _, entry in primitives.Snapshot() do
				if gate.IsTerminal() then
					break
				end

				if entry.active and entry.callback.phase == phase then
					local success: boolean, reason: string? = Observers.Run(entry.callback.callback, occurrence)

					if not success then
						report("InputPrimitiveObserver" .. (reason or "Failed"))
					end
				end
			end

			if phase == "Interpretation" and not gate.IsTerminal() then
				local accepted: boolean = pcall(recognition.Accept, occurrence)

				if not accepted then
					onFault()
				end
			end
		end

		if not gate.IsTerminal() then
			local completed: boolean, failure: any = pcall(recognition.Finish, occurrence)

			if not completed then
				report(tostring(failure))
				onFault()
			end
		end

		notifications = previousNotifications

		if not gate.IsTerminal() then
			if deferred ~= nil then
				table.insert(deferred, event)
			else
				publishInput(event)
			end
		end

		publishNotifications(batch)
		gate.LeaveDispatch()
	end

	return {
		IsPublishing = function(): boolean
			return publishingDepth == gate.Depth()
		end,
		Recognition = recognition,
		Deliver = deliver,
		PublishInput = publishInput,
		ObservePrimitive = function(phase: Types.ObserverPhase, callback: PrimitiveObserver): () -> ()
			assert(type(callback) == "function", "InvalidInputObserver")

			assert(
				phase == "Interpretation" or phase == "Arbitration" or phase == "Routing",
				"InvalidInputObserverPhase"
			)

			return primitives.Add({ phase = phase :: Types.ObserverPhase, callback = callback })
		end,
		ObserveGroups = function(callback: (Types.GestureDispatchGroup) -> ()): () -> ()
			assert(type(callback) == "function", "InvalidInputObserver")

			return dispatchGroups.Add(callback)
		end,
		Destroy = function(): ()
			envelopes.Destroy()
			table.clear(timerCallbacks)
			recognition.Destroy()
			primitives.Destroy()
			dispatchGroups.Destroy()
		end,
		ObserveEnvelopes = function(callback: (Types.InputCandidateEnvelope) -> (), demand: (() -> boolean)?): () -> ()
			assert(type(callback) == "function", "InvalidInputObserver")
			assert(demand == nil or type(demand) == "function", "InvalidInputObserver")

			return envelopes.Add({ callback = callback, hasDemand = demand })
		end,
	}
end

return Dispatch
