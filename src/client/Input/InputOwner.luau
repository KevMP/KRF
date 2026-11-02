--!strict
local Types = require(script.Parent.types)
local Validator = require(script.Parent.InputValidator)
local Constants = require(script.Parent.utils.InputConstants)
local Value = require(script.Parent.utils.InputValue)
local Observers = require(script.Parent.utils.InputObservers)
local Epochs = require(script.Parent.utils.InputEpochs)
local NativeGraph = require(script.Parent.utils.InputNativeGraph)
local Labels = require(script.Parent.utils.InputLabels)
local GestureRecognition = require(script.Parent.utils.InputGestureRecognition)
local GestureScheduler = require(script.Parent.utils.InputGestureScheduler)

type PrimitiveObserver = (Types.PrimitiveOccurrence) -> ()
type CommitObserver = (Types.InputGraphChange) -> ()
type PhasedObserver = { phase: Types.ObserverPhase, callback: PrimitiveObserver }

type PreparedRecord = {
	generation: number,
	validators: number,
	kind: string,
	graph: Types.InputGraphSnapshot?,
	profiles: any?,
	reason: string?,
	consumed: boolean,
	inputIds: { string }?,
	recognitionRevision: number?,
}

local InputOwner = {}

local function empty(generation: number): Types.InputGraphSnapshot
	local snapshot: Types.InputGraphSnapshot =
		{ generation = generation, sources = {}, contexts = {}, inputs = {}, bindings = {} }

	table.freeze(snapshot.sources)
	table.freeze(snapshot.contexts)
	table.freeze(snapshot.inputs)
	table.freeze(snapshot.bindings)

	return table.freeze(snapshot)
end

function InputOwner.new(options: Types.InputOwnerOptions): Types.InputOwner
	local owner: Types.InputOwner = {} :: Types.InputOwner
	local graph: Types.InputGraphSnapshot = empty(0)
	local states: { [string]: Epochs.State } = {}
	local destroyed: boolean = false
	local faulted: boolean = false
	local validating: boolean = false
	local fenced: boolean = false
	local dispatchDepth: number = 0
	local draining: boolean = false
	local ordinal: number = 0
	local epochId: number = 0
	local timestamp: number = 0
	local validatorVersion: number = 0
	local pending: { () -> () } = {}
	local prepared: { [any]: PreparedRecord } = setmetatable({}, { __mode = "k" })

	local primitives: Observers.Registry<PhasedObserver> = Observers.new(
		Constants.MAX_PRIMITIVE_OBSERVERS,
		"InputObserverLimitExceeded"
	) :: Observers.Registry<PhasedObserver>

	local validators: Observers.Registry<Types.GraphValidator> = Observers.new(
		Constants.MAX_GRAPH_VALIDATORS,
		"InputValidatorLimitExceeded"
	) :: Observers.Registry<Types.GraphValidator>

	local commits: Observers.Registry<CommitObserver> = Observers.new(
		Constants.MAX_COMMIT_OBSERVERS,
		"InputCommitObserverLimitExceeded"
	) :: Observers.Registry<CommitObserver>

	local labels: Labels.Owner = Labels.new()

	local dispatchGroups: Observers.Registry<(Types.GestureDispatchGroup) -> ()> = Observers.new(
		Constants.MAX_GESTURE_OBSERVERS,
		"InputGestureObserverLimitExceeded"
	) :: Observers.Registry<
		(Types.GestureDispatchGroup) -> ()
	>

	local native: NativeGraph.Owner
	local recognition: GestureRecognition.Owner
	local gestureNotifications: { Types.GestureEvent }? = nil
	local timerCallbacks: { () -> () } = {}
	local timersQueued: boolean = false
	local recognitionFenceGeneration: number? = nil
	local recognitionFenceRevision: number? = nil

	local function report(reason: string): ()
		pcall(options.ReportFault, reason)
	end

	local function unavailable(): string?
		if destroyed or not options.IsReady() then
			return "ClientNotReady"
		end

		if faulted then
			return "InputRuntimeFaulted"
		end

		if validating then
			return "InputMutationDuringValidation"
		end

		return nil
	end

	local function cleanup(): ()
		table.clear(pending)
		table.clear(prepared)
		table.clear(states)
		table.clear(timerCallbacks)
		recognition.Destroy()
		primitives.Destroy()
		validators.Destroy()
		commits.Destroy()
		dispatchGroups.Destroy()
		pcall(labels.Destroy)
		local success: boolean, reason: any = pcall(native.Destroy)

		if not success then
			report(tostring(reason))
		end

		graph = empty(graph.generation)
	end

	local function fail(retiredEpochs: { number }?): ()
		if faulted or destroyed then
			return
		end

		faulted = true
		fenced = true
		local previous: Types.InputGraphSnapshot = graph
		graph = empty(previous.generation + 1)
		recognition.Destroy()
		local epochs: { number } = table.clone(retiredEpochs or {})

		for _, state: Epochs.State in states do
			if state.active and state.epochId ~= nil then
				table.insert(epochs, state.epochId)
			end

			state.active = false
		end

		local change: Types.InputGraphChange = table.freeze({
			previous = previous,
			next = graph,
			affectedInputIds = table.freeze(Value.Keys(previous.inputs)),
			affectedContextIds = table.freeze(Value.Keys(previous.contexts)),
			reasons = table.freeze({ "InputRuntimeFaulted" }),
			invalidatedEpochIds = table.freeze(epochs),
			generation = graph.generation,
		})

		for _, entry in commits.Snapshot() do
			if entry.active then
				Observers.Run(entry.callback, change)
			end
		end

		cleanup()
		report("InputRuntimeFaulted")
	end

	local function flush(): ()
		if draining or fenced or dispatchDepth > 0 or validating then
			return
		end

		draining = true
		local total: number = 0

		while #pending > 0 and not destroyed and not faulted do
			total += 1

			if total > Constants.MAX_PENDING_MUTATIONS then
				report("InputMutationQueueLimitExceeded")
				table.clear(pending)
				break
			end

			local mutation: () -> () = assert(table.remove(pending, 1), "Expected queued input mutation")
			local success: boolean, reason: any = pcall(mutation)

			if not success then
				report(tostring(reason))
			end
		end

		draining = false
	end

	local function queue(mutation: () -> ()): (boolean, string?)
		if #pending >= Constants.MAX_PENDING_MUTATIONS then
			return false, "InputMutationQueueLimitExceeded"
		end

		table.insert(pending, mutation)

		return true, nil
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
			if destroyed or faulted then
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

	local function deliverGroup(group: Types.GestureDispatchGroup, event: Types.GestureEvent?): ()
		for _, entry in dispatchGroups.Snapshot() do
			if destroyed or faulted then
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
		if destroyed or faulted or not options.IsReady() then
			return
		end

		if fenced or validating or dispatchDepth > 0 then
			assert(#timerCallbacks < Constants.MAX_GESTURE_DEADLINES, "InputGestureDeadlineLimitExceeded")
			table.insert(timerCallbacks, callback)

			if not timersQueued then
				timersQueued = true

				local accepted: boolean = queue(function(): ()
					timersQueued = false
					local callbacks: { () -> () } = timerCallbacks
					timerCallbacks = {}

					for _, pendingCallback in callbacks do
						runTimer(pendingCallback)
					end
				end)

				if not accepted then
					fail(nil)
				end
			end

			return
		end

		dispatchDepth += 1
		local events: { Types.GestureEvent } = {}
		local previousNotifications: { Types.GestureEvent }? = gestureNotifications
		gestureNotifications = events
		local success: boolean, reason: any = pcall(callback)
		gestureNotifications = previousNotifications

		if not success then
			report(tostring(reason))
			fail(nil)
		else
			publishGestures(events)
		end

		dispatchDepth -= 1
		flush()
	end

	recognition = GestureRecognition.new({
		Now = readTime,
		Scheduler = options.Scheduler or GestureScheduler.new(readTime, report),
		RunTimer = runTimer,
		Deliver = deliverGroup,
	})

	local function deliver(
		input: Types.InputSnapshot,
		transition: Epochs.Transition,
		deferred: { Types.SemanticInputEvent }?
	): ()
		if destroyed or faulted then
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

		dispatchDepth += 1
		local gestures: { Types.GestureEvent } = {}
		local previousNotifications: { Types.GestureEvent }? = gestureNotifications
		gestureNotifications = gestures
		local interpreted: boolean = pcall(recognition.Before, occurrence)

		if not interpreted then
			fail(nil)
		end

		for _, phase: Types.ObserverPhase in { "Interpretation", "Arbitration", "Routing" } do
			for _, entry in primitives.Snapshot() do
				if destroyed or faulted then
					break
				end

				if entry.active and entry.callback.phase == phase then
					local success: boolean, reason: string? = Observers.Run(entry.callback.callback, occurrence)

					if not success then
						report("InputPrimitiveObserver" .. (reason or "Failed"))
					end
				end
			end

			if phase == "Interpretation" and not destroyed and not faulted then
				local accepted: boolean = pcall(recognition.Accept, occurrence)

				if not accepted then
					fail(nil)
				end
			end
		end

		gestureNotifications = previousNotifications

		if not destroyed and not faulted then
			if deferred ~= nil then
				table.insert(deferred, event)
			else
				local success: boolean, reason: any = pcall(options.Publish, event)

				if not success then
					report(tostring(reason))
				end
			end
		end

		publishGestures(gestures)
		dispatchDepth -= 1
	end

	native = NativeGraph.new(options.Native, function(inputId: string, kind: Types.NativeTransition, value: any): ()
		if fenced or validating or destroyed or faulted or not options.IsReady() then
			return
		end

		local state: Epochs.State? = states[inputId]

		if state == nil then
			return
		end

		local context: Types.ContextSnapshot? = graph.contexts[state.input.contextId]

		local transition: Epochs.Transition? = Epochs.Accept(
			state,
			kind,
			value,
			context ~= nil and context.enabled,
			graph.generation,
			function(): number
				epochId += 1

				return epochId
			end
		)

		if transition ~= nil then
			deliver(state.input, transition, nil)
		end

		flush()
	end)

	local function validate(nextGraph: Types.InputGraphSnapshot, profiles: any?): string?
		validating = true
		local failure: string? = nil

		for _, entry in validators.Snapshot() do
			if not entry.active then
				continue
			end

			local success: boolean, reason: string?, accepted: any, rejection: any =
				Observers.Run(entry.callback, nextGraph, profiles)

			if not success then
				failure = if reason == "Yielded" then "InputGraphValidatorYielded" else "InputGraphValidatorFailed"
			elseif type(accepted) ~= "boolean" or (rejection ~= nil and type(rejection) ~= "string") then
				failure = "InvalidGraphValidatorResult"
			elseif not accepted then
				failure = rejection or "InputGraphRejected"
			end

			if failure ~= nil then
				break
			end
		end

		validating = false

		return failure
	end

	local function compile(
		sourceId: string,
		definition: Types.InputSourceDefinition?
	): (Types.InputGraphSnapshot?, string?)
		local sources: { [string]: Types.InputSourceDefinition } = table.clone(graph.sources)

		if
			definition == nil
			or (
				next(definition.contexts or {}) == nil
				and next(definition.inputs or {}) == nil
				and next(definition.bindingOverrides or {}) == nil
				and next(definition.gestures or {}) == nil
			)
		then
			sources[sourceId] = nil
		else
			sources[sourceId] = definition
		end

		return Validator.Compose(sources, graph)
	end

	local function commit(
		nextGraph: Types.InputGraphSnapshot,
		forcedReason: string?,
		publishSelection: (() -> ())?
	): (boolean, string?)
		local unavailableReason: string? = unavailable()

		if unavailableReason ~= nil then
			return false, unavailableReason
		end

		local previous: Types.InputGraphSnapshot = graph

		if
			forcedReason == nil
			and Value.Equal(previous.sources, nextGraph.sources)
			and Value.Equal(previous.contexts, nextGraph.contexts)
		then
			return true, nil
		end

		local inputIds: { [string]: boolean } = {}
		local contextIds: { [string]: boolean } = {}
		local invalidated: { [string]: string } = {}
		local reasons: { [string]: boolean } = {}

		for contextId: string, context: Types.ContextSnapshot in previous.contexts do
			if not Value.Equal(context, nextGraph.contexts[contextId]) then
				contextIds[contextId] = true
			end
		end

		for contextId: string, context: Types.ContextSnapshot in nextGraph.contexts do
			if not Value.Equal(context, previous.contexts[contextId]) then
				contextIds[contextId] = true
			end
		end

		for inputId: string, input: Types.InputSnapshot in previous.inputs do
			local desired: Types.InputSnapshot? = nextGraph.inputs[inputId]
			local reason: string? = nil

			if forcedReason ~= nil then
				reason = forcedReason
			elseif desired == nil then
				reason = "SourceRemoved"
			elseif
				input.inputType ~= desired.inputType
				or input.contextId ~= desired.contextId
				or input.sourceId ~= desired.sourceId
			then
				reason = "InputChanged"
			else
				local before: Types.ContextSnapshot = previous.contexts[input.contextId]
				local after: Types.ContextSnapshot = nextGraph.contexts[input.contextId]

				if before.enabled and not after.enabled then
					reason = "ContextDisabled"
				elseif before.priority ~= after.priority or before.sink ~= after.sink then
					reason = "ContextChanged"
				else
					for slot: string, config: Types.BindingSnapshot in previous.bindings[inputId] do
						local nextConfig: Types.BindingSnapshot? = nextGraph.bindings[inputId][slot]

						if nextConfig == nil or not Value.Equal(config.definition, nextConfig.definition) then
							reason = "BindingChanged"
							break
						end
					end

					for slot in nextGraph.bindings[inputId] do
						if previous.bindings[inputId][slot] == nil then
							reason = "BindingChanged"
							break
						end
					end
				end
			end

			if reason ~= nil then
				invalidated[inputId] = reason
				reasons[reason] = true
			end

			if
				reason ~= nil
				or not Value.Equal(input, desired)
				or not Value.Equal(previous.bindings[inputId], nextGraph.bindings[inputId])
				or contextIds[input.contextId]
			then
				inputIds[inputId] = true
			end
		end

		for inputId: string, input: Types.InputSnapshot in nextGraph.inputs do
			if
				not Value.Equal(input, previous.inputs[inputId])
				or not Value.Equal(nextGraph.bindings[inputId], previous.bindings[inputId])
			then
				inputIds[inputId] = true
			end
		end

		local gesturePlan: GestureRecognition.Plan = recognition.Prepare(nextGraph)
		local previousRecognitionRevision: number = recognition.Revision()
		fenced = true
		local oldStates: { [string]: Epochs.State } = {}
		local cancellations: { { input: Types.InputSnapshot, transition: Epochs.Transition } } = {}
		local invalidatedEpochIds: { number } = {}

		for _, inputId: string in Value.Keys(invalidated) do
			local state: Epochs.State? = states[inputId]

			if state == nil then
				continue
			end

			oldStates[inputId] = table.clone(state)

			if state.active and state.epochId ~= nil then
				table.insert(invalidatedEpochIds, state.epochId)
			end

			local transition: Epochs.Transition? = Epochs.Cancel(state, invalidated[inputId], nextGraph.generation)

			if transition ~= nil then
				table.insert(cancellations, { input = state.input, transition = transition })
			end
		end

		local applied: boolean, reason: string? = native.Apply(previous, nextGraph, invalidated)

		if not applied then
			if reason == "NativeCommitFailed" then
				for inputId: string, state: Epochs.State in oldStates do
					if state.active then
						local read: boolean, value: any = pcall(options.Native.ReadState, native.Actions()[inputId])

						if not read or value ~= state.value then
							reason = "InputRuntimeFaulted"
							break
						end
					end
				end
			end

			if reason == "NativeCommitFailed" then
				for inputId: string, state: Epochs.State in oldStates do
					states[inputId] = state
				end
			else
				fail(invalidatedEpochIds)
			end

			fenced = false
			flush()

			return false, reason
		end

		graph = nextGraph
		recognition.Commit(gesturePlan, invalidated)

		for inputId in states do
			if graph.inputs[inputId] == nil then
				states[inputId] = nil
			end
		end

		for inputId: string, input: Types.InputSnapshot in graph.inputs do
			local state: Epochs.State? = states[inputId]

			if state == nil or state.input.inputType ~= input.inputType then
				states[inputId] = Epochs.new(input, graph.generation, oldStates[inputId] ~= nil)
			else
				state.input = input
			end

			local installed: Epochs.State = states[inputId]
			local context: Types.ContextSnapshot = graph.contexts[input.contextId]
			local oldContext: Types.ContextSnapshot? = previous.contexts[input.contextId]

			if
				context.enabled
				and not installed.active
				and input.inputType ~= Enum.InputActionType.ViewportPosition
				and (
					previous.inputs[inputId] == nil
					or oldContext == nil
					or not oldContext.enabled
					or invalidated[inputId] ~= nil
				)
			then
				local read: boolean, value: any = pcall(options.Native.ReadState, native.Actions()[inputId])

				installed.disarmed = not read
					or not Value.IsTyped(input.inputType, value)
					or value ~= Value.Neutral(input.inputType)
			end
		end

		local published: { Types.SemanticInputEvent } = {}

		local success: boolean = pcall(function(): ()
			labels.Reconcile(native.Actions())

			if publishSelection ~= nil then
				recognitionFenceGeneration = previous.generation
				recognitionFenceRevision = previousRecognitionRevision
				local selected: boolean = Observers.Run(publishSelection)
				recognitionFenceGeneration = nil
				recognitionFenceRevision = nil

				if not selected then
					error("InputSelectionPublicationFailed", 0)
				end
			end

			for _, cancellation in cancellations do
				deliver(cancellation.input, cancellation.transition, published)
			end

			local change: Types.InputGraphChange = table.freeze({
				previous = previous,
				next = graph,
				affectedInputIds = table.freeze(Value.Keys(inputIds)),
				affectedContextIds = table.freeze(Value.Keys(contextIds)),
				reasons = table.freeze(Value.Keys(reasons)),
				invalidatedEpochIds = table.freeze(invalidatedEpochIds),
				generation = graph.generation,
			})

			for _, entry in commits.Snapshot() do
				if entry.active then
					local observed: boolean = Observers.Run(entry.callback, change)

					if not observed then
						error("InputCommitObserverFailed", 0)
					end
				end
			end
		end)

		if not success then
			fail(invalidatedEpochIds)
		end

		if not destroyed and not faulted then
			for _, event: Types.SemanticInputEvent in published do
				local notified: boolean, notificationReason: any = pcall(options.Publish, event)

				if not notified then
					report(tostring(notificationReason))
				end
			end
		end

		fenced = false
		flush()

		return not faulted, if faulted then "InputRuntimeFaulted" else nil
	end

	local function applySource(sourceId: string, definition: Types.InputSourceDefinition?): (boolean, string?)
		local nextGraph: Types.InputGraphSnapshot?, reason: string? = compile(sourceId, definition)

		if nextGraph == nil then
			return false, reason
		end

		local rejected: string? = validate(nextGraph, nil)

		if rejected ~= nil then
			return false, rejected
		end

		return commit(nextGraph, nil, nil)
	end

	function owner.SetSource(sourceId: string, definition: Types.InputSourceDefinition): (boolean, string?)
		local reason: string? = unavailable()

		if reason ~= nil then
			return false, reason
		end

		local normalized: Types.InputSourceDefinition?, rejection: string? = Validator.Normalize(sourceId, definition)

		if normalized == nil then
			return false, rejection
		end

		if fenced or dispatchDepth > 0 then
			return queue(function(): ()
				local success: boolean, failure: string? = applySource(sourceId, normalized)

				if not success then
					report(failure or "InputGraphRejected")
				end
			end)
		end

		return applySource(sourceId, normalized)
	end

	function owner.RemoveSource(sourceId: string): (boolean, string?)
		local reason: string? = unavailable()

		if reason ~= nil then
			return false, reason
		end

		if type(sourceId) ~= "string" or #sourceId == 0 then
			return false, "InvalidSourceId"
		end

		if fenced or dispatchDepth > 0 then
			return queue(function(): ()
				local success: boolean, failure: string? = applySource(sourceId, nil)

				if not success then
					report(failure or "InputGraphRejected")
				end
			end)
		end

		return applySource(sourceId, nil)
	end

	function owner.SetContextEnabled(contextId: string, enabled: boolean): (boolean, string?)
		local reason: string? = unavailable()

		if reason ~= nil then
			return false, reason
		end

		if type(enabled) ~= "boolean" then
			return false, "InvalidContextEnabled"
		end

		local context: Types.ContextSnapshot? = graph.contexts[contextId]

		if context == nil then
			return false, "UnknownContext"
		end

		if fenced or dispatchDepth > 0 then
			return queue(function(): ()
				local success: boolean, failure: string? = owner.SetContextEnabled(contextId, enabled)

				if not success then
					report(failure or "InputGraphRejected")
				end
			end)
		end

		if context.enabled == enabled then
			return true, nil
		end

		local contexts: { [string]: Types.ContextSnapshot } = table.clone(graph.contexts)

		contexts[contextId] = table.freeze({
			id = context.id,
			sourceId = context.sourceId,
			priority = context.priority,
			sink = context.sink,
			enabled = enabled,
		})

		local nextGraph: Types.InputGraphSnapshot = table.freeze({
			generation = graph.generation + 1,
			sources = graph.sources,
			contexts = table.freeze(contexts),
			inputs = graph.inputs,
			bindings = graph.bindings,
		})

		local rejected: string? = validate(nextGraph, nil)

		if rejected ~= nil then
			return false, rejected
		end

		return commit(nextGraph, nil, nil)
	end

	function owner.GetInput(inputId: string): Types.InputSnapshot?
		return graph.inputs[inputId]
	end

	function owner.GetGestures(inputId: string): { [Types.GestureKind]: Types.GestureSnapshot }?
		return recognition.Get(inputId)
	end

	function owner.ObserveDispatchGroup(callback: (Types.GestureDispatchGroup) -> ()): () -> ()
		assert(type(callback) == "function", "InvalidInputObserver")

		return dispatchGroups.Add(callback)
	end

	local function resetSelection(inputIds: { string }?, reason: string): ({ string }?, string?)
		if type(reason) ~= "string" or #reason == 0 then
			return nil, "InvalidRecognitionResetReason"
		end

		if inputIds == nil then
			return Value.Keys(graph.inputs), nil
		end

		if type(inputIds) ~= "table" or getmetatable(inputIds) ~= nil then
			return nil, "InvalidRecognitionResetInputs"
		end

		local selected: { string } = {}
		local seen: { [string]: boolean } = {}

		for index, inputId in inputIds do
			if
				type(index) ~= "number"
				or index % 1 ~= 0
				or index < 1
				or index > #inputIds
				or type(inputId) ~= "string"
				or seen[inputId]
			then
				return nil, "InvalidRecognitionResetInputs"
			end

			if graph.inputs[inputId] == nil then
				return nil, "UnknownInput"
			end

			seen[inputId] = true
			table.insert(selected, inputId)
		end

		if #selected ~= #inputIds then
			return nil, "InvalidRecognitionResetInputs"
		end

		return selected, nil
	end

	function owner.ResetRecognition(inputIds: { string }?, reason: string): (boolean, string?)
		local rejection: string? = unavailable()

		if rejection ~= nil then
			return false, rejection
		end

		if fenced or dispatchDepth > 0 then
			return false, "InputMutationReentrant"
		end

		local selected: { string }?, failure: string? = resetSelection(inputIds, reason)

		if selected == nil then
			return false, failure
		end

		fenced = true
		recognition.Reset(selected)
		fenced = false
		flush()

		return true, nil
	end

	function owner.GetContext(contextId: string): Types.ContextSnapshot?
		return graph.contexts[contextId]
	end

	function owner.GetEffectiveBindings(inputId: string): { [string]: Types.BindingSnapshot }?
		return graph.bindings[inputId]
	end

	function owner.BindActionLabel(inputId: string, label: InputActionLabel): (boolean, string?)
		local reason: string? = unavailable()

		if reason ~= nil then
			return false, reason
		end

		local action: InputAction? = native.Actions()[inputId]

		if action == nil then
			return false, "UnknownInput"
		end

		if typeof(label) ~= "Instance" or not label:IsA("InputActionLabel") then
			return false, "InvalidInputActionLabel"
		end

		labels.Bind(inputId, label, action)

		return true, nil
	end

	function owner.UnbindActionLabel(label: InputActionLabel): (boolean, string?)
		local reason: string? = unavailable()

		if reason ~= nil then
			return false, reason
		end

		if typeof(label) ~= "Instance" or not label:IsA("InputActionLabel") then
			return false, "InvalidInputActionLabel"
		end

		labels.Unbind(label)

		return true, nil
	end

	function owner.ObservePrimitive(phase: Types.ObserverPhase, callback: PrimitiveObserver): () -> ()
		assert(type(callback) == "function", "InvalidInputObserver")
		assert(phase == "Interpretation" or phase == "Arbitration" or phase == "Routing", "InvalidInputObserverPhase")

		return primitives.Add({ phase = phase :: Types.ObserverPhase, callback = callback })
	end

	function owner.RegisterGraphValidator(callback: Types.GraphValidator): () -> ()
		assert(type(callback) == "function", "InvalidInputObserver")
		local stop: () -> () = validators.Add(callback)
		validatorVersion += 1
		local active: boolean = true

		return function(): ()
			if active then
				active = false
				validatorVersion += 1
				stop()
			end
		end
	end

	function owner.ObserveConfigurationCommit(callback: CommitObserver): () -> ()
		assert(type(callback) == "function", "InvalidInputObserver")

		return commits.Add(callback)
	end

	function owner.IsPressEpochActive(inputId: string, pressedEpochId: number, generation: number): boolean
		local state: Epochs.State? = states[inputId]

		return state ~= nil
			and state.input.inputType == Enum.InputActionType.Bool
			and state.active
			and state.epochId == pressedEpochId
			and state.epochGeneration == generation
	end

	local function prepare(record: PreparedRecord): (any, string?)
		local total: number = 0

		for _ in prepared do
			total += 1
		end

		if total >= Constants.MAX_PREPARED_PLANS then
			return nil, "InputPlanLimitExceeded"
		end

		local plan = table.freeze({ generation = graph.generation, token = table.freeze({}) })

		prepared[plan] = record

		return plan, nil
	end

	function owner.PrepareRecognitionReset(
		inputIds: { string }?,
		reason: string
	): (Types.PreparedRecognitionReset?, string?)
		local rejection: string? = unavailable()

		if rejection ~= nil then
			return nil, rejection
		end

		if fenced or dispatchDepth > 0 then
			return nil, "InputMutationReentrant"
		end

		local selected: { string }?, failure: string? = resetSelection(inputIds, reason)

		if selected == nil then
			return nil, failure
		end

		return prepare({
			generation = graph.generation,
			validators = validatorVersion,
			kind = "Recognition",
			inputIds = selected,
			recognitionRevision = recognition.Revision(),
			consumed = false,
		})
	end

	function owner.CommitPreparedRecognitionReset(plan: Types.PreparedRecognitionReset): (boolean, string?)
		local rejection: string? = unavailable()

		if rejection ~= nil then
			return false, rejection
		end

		if not fenced or recognitionFenceGeneration == nil then
			return false, "InputCommitFenceRequired"
		end

		local record: PreparedRecord? = prepared[plan]

		if record == nil or record.kind ~= "Recognition" then
			return false, "InvalidRecognitionReset"
		end

		if
			record.consumed
			or record.generation ~= recognitionFenceGeneration
			or record.recognitionRevision ~= recognitionFenceRevision
			or record.validators ~= validatorVersion
		then
			return false, "StaleRecognitionReset"
		end

		record.consumed = true
		recognition.Reset(record.inputIds)

		return true, nil
	end

	function owner.PrepareSource(
		sourceId: string,
		definition: Types.InputSourceDefinition?,
		profiles: any?
	): (Types.PreparedInputUpdate?, string?)
		local reason: string? = unavailable()

		if reason ~= nil then
			return nil, reason
		end

		if fenced or dispatchDepth > 0 then
			return nil, "InputMutationReentrant"
		end

		if type(sourceId) ~= "string" or #sourceId == 0 then
			return nil, "InvalidSourceId"
		end

		local normalized: Types.InputSourceDefinition? = nil

		if definition ~= nil then
			normalized, reason = Validator.Normalize(sourceId, definition)

			if normalized == nil then
				return nil, reason
			end
		end

		local desired: Types.InputGraphSnapshot?
		desired, reason = compile(sourceId, normalized)

		if desired == nil then
			return nil, reason
		end

		reason = validate(desired, profiles)

		if reason ~= nil then
			return nil, reason
		end

		return prepare({
			generation = graph.generation,
			validators = validatorVersion,
			kind = "Source",
			graph = desired,
			profiles = profiles,
			consumed = false,
		})
	end

	function owner.PrepareEpochInvalidation(reason: string): (Types.PreparedInputInvalidation?, string?)
		local unavailableReason: string? = unavailable()

		if unavailableReason ~= nil then
			return nil, unavailableReason
		end

		if fenced or dispatchDepth > 0 then
			return nil, "InputMutationReentrant"
		end

		if type(reason) ~= "string" or #reason == 0 then
			return nil, "InvalidInputInvalidationReason"
		end

		local rejected: string? = validate(graph, nil)

		if rejected ~= nil then
			return nil, rejected
		end

		return prepare({
			generation = graph.generation,
			validators = validatorVersion,
			kind = "Epoch",
			reason = reason,
			consumed = false,
		})
	end

	local function take(plan: any, kind: string): (PreparedRecord?, string?)
		local reason: string? = unavailable()

		if reason ~= nil then
			return nil, reason
		end

		if fenced or dispatchDepth > 0 then
			return nil, "InputMutationReentrant"
		end

		local record: PreparedRecord? = prepared[plan]

		if record == nil or record.kind ~= kind then
			return nil, "InvalidInputPlan"
		end

		if record.consumed or record.generation ~= graph.generation or record.validators ~= validatorVersion then
			return nil, "StaleInputPlan"
		end

		record.consumed = true

		return record, nil
	end

	function owner.CommitPrepared(plan: Types.PreparedInputUpdate): (boolean, string?)
		local record: PreparedRecord?, reason: string? = take(plan, "Source")

		if record == nil then
			return false, reason
		end

		assert(record.graph ~= nil, "Expected prepared input graph")
		reason = validate(record.graph, record.profiles)

		if reason ~= nil then
			return false, reason
		end

		return commit(record.graph, nil, nil)
	end

	function owner.CommitEpochInvalidation(
		plan: Types.PreparedInputInvalidation,
		publishSelection: () -> ()
	): (boolean, string?)
		local record: PreparedRecord?, reason: string? = take(plan, "Epoch")

		if record == nil then
			return false, reason
		end

		reason = validate(graph, nil)

		if reason ~= nil then
			return false, reason
		end

		local desired: Types.InputGraphSnapshot = table.freeze({
			generation = graph.generation + 1,
			sources = graph.sources,
			contexts = graph.contexts,
			inputs = graph.inputs,
			bindings = graph.bindings,
		})

		return commit(desired, record.reason, publishSelection)
	end

	function owner.Destroy(): ()
		if destroyed then
			return
		end

		destroyed = true
		cleanup()
	end

	return owner
end

return InputOwner
