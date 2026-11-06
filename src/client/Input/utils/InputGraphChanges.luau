--!strict
local Types = require(script.Parent.Parent.types)
local Value = require(script.Parent.InputValue)

export type Plan = {
	inputIds: { [string]: boolean },
	contextIds: { [string]: boolean },
	invalidated: { [string]: string },
	reasons: { [string]: boolean },
}

local Changes = {}

function Changes.Empty(generation: number): Types.InputGraphSnapshot
	local snapshot: Types.InputGraphSnapshot =
		{ generation = generation, sources = {}, contexts = {}, inputs = {}, bindings = {} }

	table.freeze(snapshot.sources)
	table.freeze(snapshot.contexts)
	table.freeze(snapshot.inputs)
	table.freeze(snapshot.bindings)

	return table.freeze(snapshot)
end

function Changes.Diff(
	previous: Types.InputGraphSnapshot,
	nextGraph: Types.InputGraphSnapshot,
	forcedReason: string?
): Plan
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

	return { inputIds = inputIds, contextIds = contextIds, invalidated = invalidated, reasons = reasons }
end

function Changes.Next(
	previous: Types.InputGraphSnapshot,
	contexts: { [string]: Types.ContextSnapshot }?
): Types.InputGraphSnapshot
	return table.freeze({
		generation = previous.generation + 1,
		sources = previous.sources,
		recognition = previous.recognition,
		contexts = if contexts ~= nil then table.freeze(contexts) else previous.contexts,
		inputs = previous.inputs,
		bindings = previous.bindings,
	})
end

function Changes.Event(
	previous: Types.InputGraphSnapshot,
	nextGraph: Types.InputGraphSnapshot,
	plan: Plan,
	epochs: { number }
): Types.InputGraphChange
	return table.freeze({
		previous = previous,
		next = nextGraph,
		affectedInputIds = table.freeze(Value.Keys(plan.inputIds)),
		affectedContextIds = table.freeze(Value.Keys(plan.contextIds)),
		reasons = table.freeze(Value.Keys(plan.reasons)),
		invalidatedEpochIds = table.freeze(epochs),
		generation = nextGraph.generation,
	})
end

return Changes
