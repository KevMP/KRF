--!strict
local Types = require(script.Parent.Parent.types)
local Epochs = require(script.Parent.InputEpochs)
local Gate = require(script.Parent.InputMutationGate)

export type Access = {
	Graph: () -> Types.InputGraphSnapshot,
	Available: (string) -> boolean,
	State: (string) -> Epochs.State?,
	NextEpoch: () -> number,
	Deliver: (Types.InputSnapshot, Epochs.Transition) -> (),
}

export type Owner = {
	Receive: (string, Types.NativeTransition, unknown) -> (),
	Drain: () -> (),
	IsReplaying: () -> boolean,
	Clear: () -> (),
}

type PendingRelease = { state: Epochs.State, epoch: number?, generation: number }

local Transitions = {}

-- An unchanged live epoch proves a release came from an untouched native input.
-- Invalidated/synthetic ends never become candidates for replay or rearm.
function Transitions.new(access: Access, gate: Gate.Owner): Owner
	local releases: { [string]: PendingRelease } = {}
	local replaying: boolean = false

	local function receive(inputId: string, kind: Types.NativeTransition, value: unknown): ()
		if not gate.CanDispatch() or not access.Available(inputId) then
			return
		end

		local state: Epochs.State? = access.State(inputId)

		if state == nil then
			return
		end

		if gate.IsFenced() or gate.IsValidating() or gate.IsCoordinating() or gate.IsSafetyPending() then
			if kind == "Released" and state.active and state.input.inputType == Enum.InputActionType.Bool then
				releases[inputId] = { state = state, epoch = state.epochId, generation = state.epochGeneration }
			elseif kind == "Pressed" and not state.active then
				state.disarmed = true
			end

			return
		end

		local graph: Types.InputGraphSnapshot = access.Graph()
		local context: Types.ContextSnapshot? = graph.contexts[state.input.contextId]

		local transition: Epochs.Transition? =
			Epochs.Accept(state, kind, value, context ~= nil and context.enabled, graph.generation, access.NextEpoch)

		if transition ~= nil then
			access.Deliver(state.input, transition)
		end

		gate.Flush()
	end

	return {
		Receive = receive,
		IsReplaying = function(): boolean
			return replaying
		end,
		Drain = function(): ()
			if gate.IsTerminal() or gate.IsSafetyPending() then
				table.clear(releases)

				return
			end

			local batch: { [string]: PendingRelease } = releases
			releases = {}
			replaying = true

			for inputId, pending in batch do
				local state: Epochs.State? = access.State(inputId)

				if
					state ~= nil
					and access.Available(inputId)
					and state == pending.state
					and state.active
					and state.epochId == pending.epoch
					and state.epochGeneration == pending.generation
				then
					local transition: Epochs.Transition = assert(
						Epochs.Accept(state, "Released", false, true, access.Graph().generation, access.NextEpoch),
						"Expected continuously live Bool release"
					)

					access.Deliver(state.input, transition)
				end
			end

			replaying = false
		end,
		Clear = function(): ()
			table.clear(releases)
		end,
	}
end

return Transitions
