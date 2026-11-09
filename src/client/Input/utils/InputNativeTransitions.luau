--!strict
local Types = require(script.Parent.Parent.types)
local Epochs = require(script.Parent.InputEpochs)
local Gate = require(script.Parent.InputMutationGate)

export type Access = {
	Graph: () -> Types.InputGraphSnapshot,
	Available: (string) -> boolean,
	ReadState: (string) -> unknown,
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
type PendingNeutral = { state: Epochs.State, revision: number, released: boolean }

local Transitions = {}

-- An unchanged live epoch proves a release came from an untouched native input.
-- Invalidated/synthetic ends never become candidates for replay or rearm.
function Transitions.new(access: Access, gate: Gate.Owner): Owner
	local releases: { [string]: PendingRelease } = {}
	local neutrals: { [string]: PendingNeutral } = {}
	local replaying: boolean = false

	local function reconcile(inputId: string, pending: PendingNeutral): ()
		if not pending.released then
			return
		end

		local read: boolean, value: unknown = pcall(access.ReadState, inputId)
		local state: Epochs.State? = access.State(inputId)

		local context: Types.ContextSnapshot? = if state ~= nil
			then access.Graph().contexts[state.input.contextId]
			else nil

		-- Only a complete suppressed tap on a continuously valid idle Bool can
		-- restore neutral. Retirement, unavailable input and unreadable native
		-- state retain the safety disarm. This never publishes Pressed/Released.
		if
			read
			and value == false
			and not gate.IsTerminal()
			and not gate.IsSafetyPending()
			and access.Available(inputId)
			and state ~= nil
			and state == pending.state
			and state.continuityRevision == pending.revision
			and not state.active
			and context ~= nil
			and context.enabled
		then
			state.disarmed = false
			state.value = false
		end
	end

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
				if state.input.inputType == Enum.InputActionType.Bool then
					if not state.disarmed then
						neutrals[inputId] = { state = state, revision = state.continuityRevision, released = false }
					elseif neutrals[inputId] ~= nil then
						neutrals[inputId].released = false
					end
				end

				state.disarmed = true
			elseif kind == "Released" and neutrals[inputId] ~= nil then
				neutrals[inputId].released = true
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
				table.clear(neutrals)

				return
			end

			local batch: { [string]: PendingRelease } = releases
			local neutralBatch: { [string]: PendingNeutral } = neutrals
			releases = {}
			neutrals = {}
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

			for inputId, pending in neutralBatch do
				reconcile(inputId, pending)
			end

			replaying = false
		end,
		Clear = function(): ()
			table.clear(releases)
			table.clear(neutrals)
		end,
	}
end

return Transitions
