--!strict
local Types = require(script.Parent.Parent.types)
local Value = require(script.Parent.InputValue)

export type State = {
	input: Types.InputSnapshot,
	active: boolean,
	value: any,
	disarmed: boolean,
	epochId: number?,
	epochGeneration: number,
}

export type Transition = {
	kind: "Pressed" | "Released" | "StateChanged" | "Cancelled",
	value: any,
	reason: string?,
	epochId: number?,
	generation: number,
}

export type Invalidation = {
	previous: { [string]: State },
	cancellations: { { input: Types.InputSnapshot, transition: Transition } },
	epochIds: { number },
}

local Epochs = {}

function Epochs.new(input: Types.InputSnapshot, generation: number, disarmed: boolean?): State
	return {
		input = input,
		active = false,
		value = Value.Neutral(input.inputType),
		disarmed = disarmed or false,
		epochGeneration = generation,
	}
end

function Epochs.Cancel(state: State, reason: string, generation: number): Transition?
	local wasActive: boolean = state.active

	state.active = false

	if state.input.inputType == Enum.InputActionType.ViewportPosition then
		return nil
	end

	state.disarmed = state.disarmed or wasActive
	state.value = Value.Neutral(state.input.inputType)

	if not wasActive then
		return nil
	end

	return {
		kind = "Cancelled",
		reason = reason,
		generation = if state.input.inputType == Enum.InputActionType.Bool then state.epochGeneration else generation,
		epochId = state.epochId,
	}
end

function Epochs.Accept(
	state: State,
	kind: Types.NativeTransition,
	value: any,
	enabled: boolean,
	generation: number,
	nextEpoch: () -> number
): Transition?
	local inputType: Enum.InputActionType = state.input.inputType
	local bool: boolean = inputType == Enum.InputActionType.Bool

	if bool then
		if kind == "StateChanged" then
			return nil
		end

		value = kind == "Pressed"
	elseif kind ~= "StateChanged" then
		return nil
	end

	if not Value.IsTyped(inputType, value) then
		return nil
	end

	local neutral: boolean = inputType ~= Enum.InputActionType.ViewportPosition and value == Value.Neutral(inputType)

	if state.disarmed then
		if neutral then
			state.disarmed = false
			state.value = value
		end

		return nil
	end

	if not enabled or state.value == value then
		return nil
	end

	state.value = value
	state.active = not neutral and inputType ~= Enum.InputActionType.ViewportPosition

	if bool and state.active then
		state.epochId = nextEpoch()
		state.epochGeneration = generation
	end

	return {
		kind = if bool then kind else "StateChanged",
		value = value,
		epochId = if bool then state.epochId else nil,
		generation = if bool then state.epochGeneration else generation,
	}
end

function Epochs.Invalidate(
	states: { [string]: State },
	invalidated: { [string]: string },
	generation: number
): Invalidation
	local oldStates: { [string]: State } = {}
	local cancellations: { { input: Types.InputSnapshot, transition: Transition } } = {}
	local invalidatedEpochIds: { number } = {}

	for _, inputId: string in Value.Keys(invalidated) do
		local state: State? = states[inputId]

		if state == nil then
			continue
		end

		oldStates[inputId] = table.clone(state)

		if state.active and state.epochId ~= nil then
			table.insert(invalidatedEpochIds, state.epochId)
		end

		local transition: Transition? = Epochs.Cancel(state, invalidated[inputId], generation)

		if transition ~= nil then
			table.insert(cancellations, { input = state.input, transition = transition })
		end
	end

	return { previous = oldStates, cancellations = cancellations, epochIds = invalidatedEpochIds }
end

function Epochs.Restore(
	states: { [string]: State },
	previous: { [string]: State },
	native: Types.NativeInputAdapter,
	actions: { [string]: InputAction }
): boolean
	for inputId: string, state: State in previous do
		if state.active then
			local read: boolean, value: any = pcall(native.ReadState, actions[inputId])

			if not read or value ~= state.value then
				return false
			end
		end
	end

	for inputId: string, state: State in previous do
		states[inputId] = state
	end

	return true
end

function Epochs.Install(
	states: { [string]: State },
	graph: Types.InputGraphSnapshot,
	previous: Types.InputGraphSnapshot,
	oldStates: { [string]: State },
	invalidated: { [string]: string },
	native: Types.NativeInputAdapter,
	actions: { [string]: InputAction }
): ()
	for inputId in states do
		if graph.inputs[inputId] == nil then
			states[inputId] = nil
		end
	end

	for inputId: string, input: Types.InputSnapshot in graph.inputs do
		local state: State? = states[inputId]

		if state == nil or state.input.inputType ~= input.inputType then
			states[inputId] = Epochs.new(input, graph.generation, oldStates[inputId] ~= nil)
		else
			state.input = input
		end

		local installed: State = states[inputId]
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
			local read: boolean, value: any = pcall(native.ReadState, actions[inputId])

			installed.disarmed = not read
				or not Value.IsTyped(input.inputType, value)
				or value ~= Value.Neutral(input.inputType)
		end
	end
end

return Epochs
