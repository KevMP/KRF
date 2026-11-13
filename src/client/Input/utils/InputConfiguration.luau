--!strict
local Types = require(script.Parent.Parent.types)
local Validator = require(script.Parent.Parent.InputValidator)
local Compiler = require(script.Parent.InputGraphCompiler)
local Changes = require(script.Parent.InputGraphChanges)
local StateCommit = require(script.Parent.InputStateCommit)
local MutationGate = require(script.Parent.InputMutationGate)
local Dispatch = require(script.Parent.InputDispatch)
local GraphObservers = require(script.Parent.InputGraphObservers)
local Observers = require(script.Parent.Parent.Parent.Parent.shared.Signal.PrivateObservers)

export type SelectionFence = StateCommit.SelectionFence
export type Options = StateCommit.Options

export type Owner = StateCommit.Owner & {
	SetSource: (string, Types.InputSourceDefinition) -> (boolean, string?),
	RemoveSource: (string) -> (boolean, string?),
	SetContextEnabled: (string, boolean) -> (boolean, string?),
	CompileSource: (string, Types.InputSourceDefinition?) -> (Types.InputGraphSnapshot?, string?),
	CompileUpdate: ({ Types.InputSourceUpdate }, { Types.InputContextUpdate }) -> (Types.InputGraphSnapshot?, string?),
}

local Configuration = {}

function Configuration.new(
	options: Options,
	gate: MutationGate.Owner,
	dispatch: Dispatch.Owner,
	observers: GraphObservers.Owner
): Owner
	local state: StateCommit.Owner = StateCommit.new(options, gate, dispatch, observers)
	local owner: Owner
	local report: (string) -> () = options.ReportFault

	local function applySource(sourceId: string, definition: Types.InputSourceDefinition?): (boolean, string?)
		local nextGraph: Types.InputGraphSnapshot?, reason: string? = Compiler.Compile(
			state.Graph(),
			{ { sourceId = sourceId, definition = definition } },
			{}
		)

		if nextGraph == nil then
			return false, reason
		end

		local rejected: string? = observers.Validate(nextGraph, nil)

		if rejected ~= nil then
			return false, rejected
		end

		local accepted: boolean, failure: string? = state.Commit(nextGraph, nil, nil)

		return accepted, failure
	end

	local function SetSource(sourceId: string, definition: Types.InputSourceDefinition): (boolean, string?)
		Observers.CheckReentry()
		local reason: string? = if gate.IsCoordinating() then "DispatchInProgress" else gate.Unavailable()

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
		Observers.CheckReentry()
		local reason: string? = if gate.IsCoordinating() then "DispatchInProgress" else gate.Unavailable()

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
		Observers.CheckReentry()
		local reason: string? = if gate.IsCoordinating() then "DispatchInProgress" else gate.Unavailable()

		if reason ~= nil then
			return false, reason
		end

		if type(enabled) ~= "boolean" then
			return false, "InvalidContextEnabled"
		end

		local context: Types.ContextSnapshot? = state.Graph().contexts[contextId]

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

		local contexts: { [string]: Types.ContextSnapshot } = table.clone(state.Graph().contexts)

		contexts[contextId] = table.freeze({
			id = context.id,
			sourceId = context.sourceId,
			priority = context.priority,
			sink = context.sink,
			enabled = enabled,
		})

		local nextGraph: Types.InputGraphSnapshot = Changes.Next(state.Graph(), contexts)

		local rejected: string? = observers.Validate(nextGraph, nil)

		if rejected ~= nil then
			return false, rejected
		end

		local accepted: boolean, failure: string? = state.Commit(nextGraph, nil, nil)

		return accepted, failure
	end

	owner = {
		SetFocusAvailable = state.SetFocusAvailable,
		SetDeviceAvailable = state.SetDeviceAvailable,
		SetSource = SetSource,
		RemoveSource = RemoveSource,
		SetContextEnabled = SetContextEnabled,
		CompileSource = function(
			sourceId: string,
			definition: Types.InputSourceDefinition?
		): (Types.InputGraphSnapshot?, string?)
			return Compiler.Compile(state.Graph(), { { sourceId = sourceId, definition = definition } }, {})
		end,
		CompileUpdate = function(
			updates: { Types.InputSourceUpdate },
			enabled: { Types.InputContextUpdate }
		): (Types.InputGraphSnapshot?, string?)
			return Compiler.Compile(state.Graph(), updates, enabled)
		end,
		Graph = state.Graph,
		Commit = state.Commit,
		SelectionFence = state.SelectionFence,
		Disarm = state.Disarm,
		GetInput = state.GetInput,
		GetContext = state.GetContext,
		GetEffectiveBindings = state.GetEffectiveBindings,
		BindActionLabel = state.BindActionLabel,
		UnbindActionLabel = state.UnbindActionLabel,
		IsPressEpochActive = state.IsPressEpochActive,
		DrainNative = state.DrainNative,
		IsReplaying = state.IsReplaying,
		Fail = state.Fail,
		Destroy = state.Destroy,
	}

	return owner
end

return Configuration
