--!strict
local Types = require(script.Parent.Parent.types)
local Validator = require(script.Parent.Parent.InputValidator)
local Value = require(script.Parent.InputValue)
local Observers = require(script.Parent.Parent.Parent.Parent.shared.Signal.PrivateObservers)
local Epochs = require(script.Parent.InputEpochs)
local NativeGraph = require(script.Parent.InputNativeGraph)
local Labels = require(script.Parent.InputLabels)
local Changes = require(script.Parent.InputGraphChanges)
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
	Disarm: (reason: string) -> (boolean, string?),
	Graph: () -> Types.InputGraphSnapshot,
	CompileSource: (sourceId: string, definition: Types.InputSourceDefinition?) -> (Types.InputGraphSnapshot?, string?),
	Commit: (nextGraph: Types.InputGraphSnapshot, reason: string?, publishSelection: (() -> ())?) -> (boolean, string?),
	SelectionFence: () -> SelectionFence?,
	SetSource: (sourceId: string, definition: Types.InputSourceDefinition) -> (boolean, string?),
	RemoveSource: (sourceId: string) -> (boolean, string?),
	SetContextEnabled: (contextId: string, enabled: boolean) -> (boolean, string?),
	GetInput: (inputId: string) -> Types.InputSnapshot?,
	GetContext: (contextId: string) -> Types.ContextSnapshot?,
	GetEffectiveBindings: (inputId: string) -> { [string]: Types.BindingSnapshot }?,
	BindActionLabel: (inputId: string, label: InputActionLabel) -> (boolean, string?),
	UnbindActionLabel: (label: InputActionLabel) -> (boolean, string?),
	IsPressEpochActive: (inputId: string, epochId: number, generation: number) -> boolean,
	Fail: (retiredEpochs: { number }?) -> (),
	Destroy: () -> (),
}

local Configuration = {}

-- Graph, epochs and native application share one atomic installation boundary.
-- A terminal transition installs the empty graph before validity notification.
function Configuration.new(
	options: Options,
	gate: MutationGate.Owner,
	dispatch: Dispatch.Owner,
	observers: GraphObservers.Owner
): Owner
	local graph: Types.InputGraphSnapshot = Changes.Empty(0)
	local states: { [string]: Epochs.State } = {}
	local epochId: number = 0
	local selectionFence: SelectionFence? = nil
	local labels: Labels.Owner = Labels.new()
	local recognition: RecognitionPipeline.Owner = dispatch.Recognition
	local native: NativeGraph.Owner
	local owner: Owner
	local report: (string) -> () = options.ReportFault

	local function cleanup(): ()
		gate.Clear()
		options.ClearPlans()
		table.clear(states)
		dispatch.Destroy()
		observers.Destroy()
		pcall(labels.Destroy)
		local success: boolean, reason: any = pcall(native.Destroy)

		if not success then
			report(tostring(reason))
		end

		graph = Changes.Empty(graph.generation)
	end

	local function fail(retiredEpochs: { number }?): ()
		if not gate.Fault() then
			return
		end

		local previous: Types.InputGraphSnapshot = graph
		graph = Changes.Empty(previous.generation + 1)
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

	native = NativeGraph.new(options.Native, function(inputId: string, kind: Types.NativeTransition, value: any): ()
		if gate.IsFenced() or gate.IsValidating() or not gate.CanDispatch() then
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
			dispatch.Deliver(state.input, transition, nil)
		end

		gate.Flush()
	end)

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
				and next(definition.sequences or {}) == nil
				and next(definition.sequenceGroups or {}) == nil
				and next(definition.recognizers or {}) == nil
			)
		then
			sources[sourceId] = nil
		else
			sources[sourceId] = definition
		end

		return Validator.Compose(sources, graph)
	end

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
		publishSelection: (() -> ())?
	): (boolean, string?)
		local unavailableReason: string? = gate.Unavailable()

		if unavailableReason ~= nil then
			return false, unavailableReason
		end

		local previous: Types.InputGraphSnapshot = graph

		if
			forcedReason == nil
			and Value.Equal(previous.sources, nextGraph.sources)
			and Value.Equal(previous.contexts, nextGraph.contexts)
		then
			if publishSelection == nil then
				return true, nil
			end

			gate.SetFenced(true)

			local published: boolean = publishFenced(publishSelection, graph, recognition.Revision(), {})

			if not published then
				fail(nil)
			end

			gate.SetFenced(false)
			gate.Flush()

			return published, if published then nil else "InputRuntimeFaulted"
		end

		local changes: Changes.Plan = Changes.Diff(previous, nextGraph, forcedReason)
		local gesturePlan: RecognitionPipeline.Plan = recognition.Prepare(nextGraph)
		local previousRecognitionRevision: number = recognition.Revision()
		gate.SetFenced(true)
		local invalidation: Epochs.Invalidation = Epochs.Invalidate(states, changes.invalidated, nextGraph.generation)
		local applied: boolean, reason: string? = native.Apply(previous, nextGraph, changes.invalidated)

		if not applied then
			if
				reason == "NativeCommitFailed"
				and not Epochs.Restore(states, invalidation.previous, options.Native, native.Actions())
			then
				reason = "InputRuntimeFaulted"
			end

			if reason ~= "NativeCommitFailed" then
				fail(invalidation.epochIds)
			end

			gate.SetFenced(false)
			gate.Flush()

			return false, reason
		end

		graph = nextGraph
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
		gate.Flush()

		return not gate.IsFaulted(), if gate.IsFaulted() then "InputRuntimeFaulted" else nil
	end

	local function applySource(sourceId: string, definition: Types.InputSourceDefinition?): (boolean, string?)
		local nextGraph: Types.InputGraphSnapshot?, reason: string? = compile(sourceId, definition)

		if nextGraph == nil then
			return false, reason
		end

		local rejected: string? = observers.Validate(nextGraph, nil)

		if rejected ~= nil then
			return false, rejected
		end

		return commit(nextGraph, nil, nil)
	end

	local function SetSource(sourceId: string, definition: Types.InputSourceDefinition): (boolean, string?)
		local reason: string? = gate.Unavailable()

		if reason ~= nil then
			return false, reason
		end

		local normalized: Types.InputSourceDefinition?, rejection: string? = Validator.Normalize(sourceId, definition)

		if normalized == nil then
			return false, rejection
		end

		if gate.IsBusy() then
			return gate.Queue(function(): ()
				local success: boolean, failure: string? = applySource(sourceId, normalized)

				if not success then
					report(failure or "InputGraphRejected")
				end
			end)
		end

		return applySource(sourceId, normalized)
	end

	local function RemoveSource(sourceId: string): (boolean, string?)
		local reason: string? = gate.Unavailable()

		if reason ~= nil then
			return false, reason
		end

		if type(sourceId) ~= "string" or #sourceId == 0 then
			return false, "InvalidSourceId"
		end

		if gate.IsBusy() then
			return gate.Queue(function(): ()
				local success: boolean, failure: string? = applySource(sourceId, nil)

				if not success then
					report(failure or "InputGraphRejected")
				end
			end)
		end

		return applySource(sourceId, nil)
	end

	local function SetContextEnabled(contextId: string, enabled: boolean): (boolean, string?)
		local reason: string? = gate.Unavailable()

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

		if gate.IsBusy() then
			return gate.Queue(function(): ()
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

		local nextGraph: Types.InputGraphSnapshot = Changes.Next(graph, contexts)

		local rejected: string? = observers.Validate(nextGraph, nil)

		if rejected ~= nil then
			return false, rejected
		end

		return commit(nextGraph, nil, nil)
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

	local function BindActionLabel(inputId: string, label: InputActionLabel): (boolean, string?)
		local reason: string? = gate.Unavailable()

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

	local function UnbindActionLabel(label: InputActionLabel): (boolean, string?)
		local reason: string? = gate.Unavailable()

		if reason ~= nil then
			return false, reason
		end

		if typeof(label) ~= "Instance" or not label:IsA("InputActionLabel") then
			return false, "InvalidInputActionLabel"
		end

		labels.Unbind(label)

		return true, nil
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
		Disarm = function(reason: string): (boolean, string?)
			if gate.IsBusy() then
				return false, "InputMutationReentrant"
			end

			return commit(Changes.Next(graph, nil), reason, nil)
		end,
		Graph = function(): Types.InputGraphSnapshot
			return graph
		end,
		CompileSource = compile,
		Commit = commit,
		SelectionFence = function(): SelectionFence?
			return selectionFence
		end,
		SetSource = SetSource,
		RemoveSource = RemoveSource,
		SetContextEnabled = SetContextEnabled,
		GetInput = GetInput,
		GetContext = GetContext,
		GetEffectiveBindings = GetEffectiveBindings,
		BindActionLabel = BindActionLabel,
		UnbindActionLabel = UnbindActionLabel,
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

return Configuration
