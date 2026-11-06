--!strict
local Types = require(script.Parent.Parent.types)
local Constants = require(script.Parent.InputConstants)
local Value = require(script.Parent.InputValue)
local Observers = require(script.Parent.InputObservers)
local Epochs = require(script.Parent.InputEpochs)
local MutationGate = require(script.Parent.InputMutationGate)
local RecognitionPipeline = require(script.Parent.InputRecognitionPipeline)
local GestureScheduler = require(script.Parent.InputGestureScheduler)

type PrimitiveObserver = (Types.PrimitiveOccurrence) -> ()
type PhasedObserver = { phase: Types.ObserverPhase, callback: PrimitiveObserver }

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
	Recognition: RecognitionPipeline.Owner,
	Deliver: (input: Types.InputSnapshot, transition: Epochs.Transition, deferred: { Types.SemanticInputEvent }?) -> (),
	PublishInput: (event: Types.SemanticInputEvent) -> (),
	ObservePrimitive: (phase: Types.ObserverPhase, callback: PrimitiveObserver) -> () -> (),
	ObserveGroups: (callback: (Types.GestureDispatchGroup) -> ()) -> () -> (),
	ObserveEnvelopes: (callback: (Types.InputCandidateEnvelope) -> ()) -> () -> (),
	Destroy: () -> (),
}

local Dispatch = {}

-- Owns occurrence stamping and the private-before-public delivery sequence.
function Dispatch.new(options: Options, gate: MutationGate.Owner, onFault: () -> ()): Owner
	local ordinal: number = 0
	local timestamp: number = 0
	local gestureNotifications: { Types.GestureEvent }? = nil
	local sequenceNotifications: { Types.SequenceMatchEvent }? = nil
	local customNotifications: { Types.CustomRecognitionEvent }? = nil
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
	local envelopes: Observers.Registry<(Types.InputCandidateEnvelope) -> ()> = Observers.new(
		Constants.MAX_CANDIDATE_OBSERVERS,
		"InputCandidateObserverLimitExceeded"
	) :: Observers.Registry<
		(Types.InputCandidateEnvelope) -> ()
	>

	local function publishInput(event: Types.SemanticInputEvent): ()
		local success: boolean, reason: any = pcall(options.Publish, event)

		if not success then
			report(tostring(reason))
		end
	end

	local function readTime(): number
		local now: number = options.Now()

		if Value.IsFinite(now) then
			timestamp = math.max(timestamp, now)
		end

		return timestamp
	end

	local function publishGestures(events: { Types.GestureEvent }): ()
		for _, event: Types.GestureEvent in events do
			if gate.IsTerminal() then
				break
			end

			local publish: ((Types.GestureEvent) -> ())? = options.PublishGesture

			if publish ~= nil then
				local success: boolean, reason: any = pcall(publish, event)

				if not success then
					report(tostring(reason))
				end
			end
		end
	end

	local function publishRecognition(
		customs: { Types.CustomRecognitionEvent },
		sequences: { Types.SequenceMatchEvent }
	): ()
		-- Both lanes share one ordinal counter and each is already ascending.
		local customIndex: number = 1
		local sequenceIndex: number = 1

		while not gate.IsTerminal() do
			local custom: Types.CustomRecognitionEvent? = customs[customIndex]
			local sequence: Types.SequenceMatchEvent? = sequences[sequenceIndex]
			local success: boolean = true
			local reason: any = nil

			if custom ~= nil and (sequence == nil or custom.ordinal < sequence.ordinal) then
				customIndex += 1

				local publish: ((Types.CustomRecognitionEvent) -> ())? = options.PublishRecognizer

				if publish ~= nil then
					success, reason = pcall(publish, custom)
				end
			elseif sequence ~= nil then
				sequenceIndex += 1

				local publish: ((Types.SequenceMatchEvent) -> ())? = options.PublishSequence

				if publish ~= nil then
					success, reason = pcall(publish, sequence)
				end
			else
				break
			end

			if not success then
				report(tostring(reason))
			end
		end
	end

	local function deliverEnvelope(envelope: Types.InputCandidateEnvelope): ()
		for _, entry in envelopes.Snapshot() do
			if gate.IsTerminal() then
				break
			end

			if entry.active then
				local success: boolean, reason: string? = Observers.Run(entry.callback, envelope)

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

		if event ~= nil and gestureNotifications ~= nil then
			table.insert(gestureNotifications, event)
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
		local events: { Types.GestureEvent } = {}
		local previousNotifications: { Types.GestureEvent }? = gestureNotifications
		local sequences: { Types.SequenceMatchEvent } = {}
		local customs: { Types.CustomRecognitionEvent } = {}
		local previousSequences: { Types.SequenceMatchEvent }? = sequenceNotifications
		local previousCustoms: { Types.CustomRecognitionEvent }? = customNotifications
		sequenceNotifications = sequences
		customNotifications = customs
		gestureNotifications = events

		local success: boolean, reason: any = pcall(function(): ()
			callback()
			recognition.Finish(nil)
		end)

		gestureNotifications = previousNotifications
		sequenceNotifications = previousSequences
		customNotifications = previousCustoms

		if not success then
			report(tostring(reason))
			onFault()
		else
			publishGestures(events)
			publishRecognition(customs, sequences)
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
		IsEpochActive = options.IsEpochActive,
		Report = report,
		NotifySequence = function(event: Types.SequenceMatchEvent): ()
			if sequenceNotifications ~= nil then
				table.insert(sequenceNotifications, event)
			end
		end,
		NotifyCustom = function(event: Types.CustomRecognitionEvent): ()
			if customNotifications ~= nil then
				table.insert(customNotifications, event)
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
		local gestures: { Types.GestureEvent } = {}
		local previousNotifications: { Types.GestureEvent }? = gestureNotifications
		local sequences: { Types.SequenceMatchEvent } = {}
		local customs: { Types.CustomRecognitionEvent } = {}
		local previousSequences: { Types.SequenceMatchEvent }? = sequenceNotifications
		local previousCustoms: { Types.CustomRecognitionEvent }? = customNotifications
		sequenceNotifications = sequences
		customNotifications = customs
		gestureNotifications = gestures
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

		gestureNotifications = previousNotifications
		sequenceNotifications = previousSequences
		customNotifications = previousCustoms

		if not gate.IsTerminal() then
			if deferred ~= nil then
				table.insert(deferred, event)
			else
				publishInput(event)
			end
		end

		publishGestures(gestures)
		publishRecognition(customs, sequences)
		gate.LeaveDispatch()
	end

	return {
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
		ObserveEnvelopes = function(callback: (Types.InputCandidateEnvelope) -> ()): () -> ()
			assert(type(callback) == "function", "InvalidInputObserver")

			return envelopes.Add(callback)
		end,
	}
end

return Dispatch
