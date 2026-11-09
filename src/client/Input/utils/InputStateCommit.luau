--!strict
local Types = require(script.Parent.Parent.types)
local Value = require(script.Parent.InputValue)
local Observers = require(script.Parent.Parent.Parent.Parent.shared.Signal.PrivateObservers)
local Epochs = require(script.Parent.InputEpochs)
local NativeGraph = require(script.Parent.InputNativeGraph)
local Labels = require(script.Parent.InputLabels)
local Changes = require(script.Parent.InputGraphChanges)
local Availability = require(script.Parent.InputAvailability)
local NativeTransitions = require(script.Parent.InputNativeTransitions)
local MutationGate = require(script.Parent.InputMutationGate)
local Dispatch = require(script.Parent.InputDispatch)
local GraphObservers = require(script.Parent.InputGraphObservers)
local RecognitionPipeline = require(script.Parent.InputRecognitionPipeline)

export type SelectionFence = Types.InputCommitContext & { read generation: number, read recognitionRevision: number }

export type Options = {
	Native: Types.NativeInputAdapter,
	ReportFault: (string) -> (),
	ClearPlans: () -> (),
}

export type Owner = {
	SetFocusAvailable: (boolean) -> (),
	SetDeviceAvailable: (Enum.UserInputType, boolean) -> (),
	Disarm: (reason: string) -> (boolean, string?),
	Graph: () -> Types.InputGraphSnapshot,
	Commit: (
		nextGraph: Types.InputGraphSnapshot,
		reason: string?,
		publishSelection: (() -> ())?,
		invalidated: { [string]: string }?
	) -> (boolean, string?, Types.InputCommitFailurePhase?),
	SelectionFence: () -> SelectionFence?,
	GetInput: (inputId: string) -> Types.InputSnapshot?,
	GetContext: (contextId: string) -> Types.ContextSnapshot?,
	GetEffectiveBindings: (inputId: string) -> { [string]: Types.BindingSnapshot }?,
	BindActionLabel: (inputId: string, label: InputActionLabel) -> (boolean, string?),
	UnbindActionLabel: (label: InputActionLabel) -> (boolean, string?),
	IsPressEpochActive: (inputId: string, epochId: number, generation: number) -> boolean,
	Fail: (retiredEpochs: { number }?) -> (),
	DrainNative: () -> (),
	IsReplaying: () -> boolean,
	Destroy: () -> (),
}

local StateCommit = {}

-- Graph, epochs and native application share one atomic installation boundary.
-- A terminal transition installs the empty graph before validity notification.
function StateCommit.new(
	options: Options,
	gate: MutationGate.Owner,
	dispatch: Dispatch.Owner,
	observers: GraphObservers.Owner
): Owner
	local graph: Types.InputGraphSnapshot = Changes.Empty(0)
	local states: { [string]: Epochs.State } = {}

	local availability: Availability.Owner = Availability.new(function(): Types.InputGraphSnapshot
		return graph
	end)

	local epochId: number = 0
	local pendingCancellations: { { input: Types.InputSnapshot, transition: Epochs.Transition } } = {}
	local failing: boolean = false
	local transitions: NativeTransitions.Owner
	local selectionFence: SelectionFence? = nil
	local native: NativeGraph.Owner

	local labels: Labels.Owner = Labels.new(gate.Unavailable, function(): { [string]: InputAction }
		return native.Actions()
	end)

	local recognition: RecognitionPipeline.Owner = dispatch.Recognition
	local owner: Owner
	local report: (string) -> () = options.ReportFault

	local function cleanup(): ()
		gate.Clear()
		transitions.Clear()
		options.ClearPlans()
		table.clear(states)
		dispatch.Destroy()
		observers.Destroy()
		pcall(labels.Destroy)
		local success: boolean, reason: unknown = pcall(native.Destroy)

		if not success then
			report(tostring(reason))
		end

		graph = Changes.Empty(graph.generation)
	end

	local function fail(retiredEpochs: { number }?): ()
		if failing or gate.IsTerminal() then
			return
		end

		failing = true
		local previous: Types.InputGraphSnapshot = graph
		graph = Changes.Empty(previous.generation + 1)

		for _, cancellation in pendingCancellations do
			dispatch.Deliver(cancellation.input, cancellation.transition, nil)
		end

		pendingCancellations = {}
		gate.Fault()
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

		observers.Notify(change, false)
		cleanup()
		report("InputRuntimeFaulted")
	end

	transitions = NativeTransitions.new({
		Graph = function(): Types.InputGraphSnapshot
			return graph
		end,
		Available = availability.IsAvailable,
		ReadState = function(inputId: string): unknown
			local action: InputAction? = native.Actions()[inputId]

			return if action ~= nil then options.Native.ReadState(action) else nil
		end,
		State = function(inputId: string): Epochs.State?
			return states[inputId]
		end,
		NextEpoch = function(): number
			epochId += 1

			return epochId
		end,
		Deliver = function(input: Types.InputSnapshot, transition: Epochs.Transition): ()
			dispatch.Deliver(input, transition, nil)
		end,
	}, gate)

	native = NativeGraph.new(options.Native, transitions.Receive)

	local function publishFenced(
		publishSelection: () -> (),
		previous: Types.InputGraphSnapshot,
		recognitionRevision: number,
		invalidated: { [string]: string }
	): boolean
		selectionFence = table.freeze({
			generation = previous.generation,
			recognitionRevision = recognitionRevision,
			previous = previous,
			invalidatedInputIds = table.freeze(table.clone(invalidated)),
		})

		local published: boolean = Observers.Run(publishSelection)
		selectionFence = nil

		return published
	end

	local function commit(
		nextGraph: Types.InputGraphSnapshot,
		forcedReason: string?,
		publishSelection: (() -> ())?,
		forcedInputs: { [string]: string }?
	): (boolean, string?, Types.InputCommitFailurePhase?)
		local unavailableReason: string? = gate.Unavailable()

		if unavailableReason ~= nil then
			return false, unavailableReason, "Rejected"
		end

		local previous: Types.InputGraphSnapshot = graph

		if
			forcedReason == nil
			and forcedInputs == nil
			and Value.Equal(previous.sources, nextGraph.sources)
			and Value.Equal(previous.contexts, nextGraph.contexts)
		then
			if publishSelection == nil then
				return true, nil, nil
			end

			gate.SetFenced(true)

			local published: boolean = publishFenced(publishSelection, graph, recognition.Revision(), {})

			if not published then
				fail(nil)
			end

			gate.SetFenced(false)
			gate.Flush()

			return published, if published then nil else "InputRuntimeFaulted", if published then nil else "Failed"
		end

		local changes: Changes.Plan = Changes.Diff(previous, nextGraph, forcedReason)

		if forcedInputs ~= nil then
			for inputId, reason in forcedInputs do
				if previous.inputs[inputId] ~= nil then
					changes.invalidated[inputId] = reason
					changes.inputIds[inputId] = true
					changes.reasons[reason] = true
				end
			end
		end

		local gesturePlan: RecognitionPipeline.Plan = recognition.Prepare(nextGraph)
		local previousRecognitionRevision: number = recognition.Revision()
		gate.SetFenced(true)
		local invalidation: Epochs.Invalidation = Epochs.Invalidate(states, changes.invalidated, nextGraph.generation)
		pendingCancellations = invalidation.cancellations
		local applied: boolean, reason: string? = native.Apply(previous, nextGraph, changes.invalidated)

		if not applied then
			if
				reason == "NativeCommitFailed"
				and not Epochs.Restore(
					states,
					invalidation.previous,
					options.Native,
					native.Actions(),
					gate.IsCoordinating()
				)
			then
				reason = "InputRuntimeFaulted"
			end

			if reason ~= "NativeCommitFailed" then
				fail(invalidation.epochIds)
			elseif gate.IsCoordinating() then
				recognition.Reset(Value.Keys(changes.invalidated))

				for _, cancellation in pendingCancellations do
					dispatch.Deliver(cancellation.input, cancellation.transition, nil)
				end

				observers.Notify(Changes.Event(previous, graph, changes, invalidation.epochIds), true)
			end

			pendingCancellations = {}

			gate.SetFenced(false)
			gate.Flush()

			return false, reason, if reason == "NativeCommitFailed" then "Restored" else "Failed"
		end

		if gate.IsTerminal() then
			return false, "ClientNotReady", "Failed"
		end

		graph = nextGraph
		availability.Reconcile()
		recognition.Commit(gesturePlan, changes.invalidated)

		Epochs.Install(
			states,
			graph,
			previous,
			invalidation.previous,
			changes.invalidated,
			options.Native,
			native.Actions()
		)

		for inputId, state in states do
			local invalidationReason: string? = changes.invalidated[inputId]

			if
				(
					not availability.IsAvailable(inputId)
					or invalidationReason == "FocusLost"
					or invalidationReason == "DeviceDisconnected"
					or invalidationReason == "InputOwnershipChanged"
				) and state.input.inputType ~= Enum.InputActionType.ViewportPosition
			then
				state.disarmed = true
			end
		end

		local published: { Types.SemanticInputEvent } = {}

		local success: boolean = pcall(function(): ()
			labels.Reconcile(native.Actions())

			if publishSelection ~= nil then
				if not publishFenced(publishSelection, previous, previousRecognitionRevision, changes.invalidated) then
					error("InputSelectionPublicationFailed", 0)
				end
			end

			for _, cancellation in invalidation.cancellations do
				dispatch.Deliver(cancellation.input, cancellation.transition, published)
			end

			pendingCancellations = {}
			observers.Notify(Changes.Event(previous, graph, changes, invalidation.epochIds), true)
		end)

		if not success then
			fail(invalidation.epochIds)
		end

		if not gate.IsTerminal() then
			for _, event: Types.SemanticInputEvent in published do
				dispatch.PublishInput(event)
			end
		end

		gate.SetFenced(false)

		if not gate.IsCoordinating() then
			transitions.Drain()
		end

		gate.Flush()

		return not gate.IsFaulted(),
			if gate.IsFaulted() then "InputRuntimeFaulted" else nil,
			if gate.IsFaulted() then "Failed" else nil
	end

	local function GetInput(inputId: string): Types.InputSnapshot?
		return graph.inputs[inputId]
	end

	local function GetContext(contextId: string): Types.ContextSnapshot?
		return graph.contexts[contextId]
	end

	local function GetEffectiveBindings(inputId: string): { [string]: Types.BindingSnapshot }?
		return graph.bindings[inputId]
	end

	local function IsPressEpochActive(inputId: string, pressedEpochId: number, generation: number): boolean
		local state: Epochs.State? = states[inputId]

		return state ~= nil
			and state.input.inputType == Enum.InputActionType.Bool
			and state.active
			and state.epochId == pressedEpochId
			and state.epochGeneration == generation
	end

	owner = {
		SetFocusAvailable = availability.SetFocus,
		SetDeviceAvailable = availability.SetDevice,
		DrainNative = transitions.Drain,
		IsReplaying = transitions.IsReplaying,
		Disarm = function(reason: string): (boolean, string?)
			if gate.IsBusy() then
				return false, "InputMutationReentrant"
			end

			local accepted: boolean, failure: string? = commit(Changes.Next(graph, nil), reason, nil)

			return accepted, failure
		end,
		Graph = function(): Types.InputGraphSnapshot
			return graph
		end,
		Commit = commit,
		SelectionFence = function(): SelectionFence?
			return selectionFence
		end,
		GetInput = GetInput,
		GetContext = GetContext,
		GetEffectiveBindings = GetEffectiveBindings,
		BindActionLabel = labels.BindActionLabel,
		UnbindActionLabel = labels.UnbindActionLabel,
		IsPressEpochActive = IsPressEpochActive,
		Fail = fail,
		Destroy = function(): ()
			if gate.Destroy() then
				cleanup()
			end
		end,
	}

	return owner
end

return StateCommit
