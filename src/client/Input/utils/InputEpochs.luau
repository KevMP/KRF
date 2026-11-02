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

return Epochs
