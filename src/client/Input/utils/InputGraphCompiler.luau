--!strict
local Types = require(script.Parent.Parent.types)
local Validator = require(script.Parent.Parent.InputValidator)
local Value = require(script.Parent.InputValue)

local Compiler = {}

local function empty(definition: Types.InputSourceDefinition): boolean
	return next(definition.contexts or {}) == nil
		and next(definition.inputs or {}) == nil
		and next(definition.bindingOverrides or {}) == nil
		and next(definition.gestures or {}) == nil
		and next(definition.sequences or {}) == nil
		and next(definition.sequenceGroups or {}) == nil
		and next(definition.recognizers or {}) == nil
end

-- All source changes are normalized before composing once. Context enablement
-- applies to that final graph, including same-ID ownership transfers.
function Compiler.Compile(
	previous: Types.InputGraphSnapshot,
	updates: { Types.InputSourceUpdate },
	enabled: { Types.InputContextUpdate }
): (Types.InputGraphSnapshot?, string?)
	local sources: { [string]: Types.InputSourceDefinition } = table.clone(previous.sources)

	for _, update in updates do
		if type(update.sourceId) ~= "string" or #update.sourceId == 0 then
			return nil, "InvalidSourceId"
		end

		local definition: Types.InputSourceDefinition? = update.definition

		if definition ~= nil then
			local normalized: Types.InputSourceDefinition?, reason: string? =
				Validator.Normalize(update.sourceId, definition)

			if normalized == nil then
				return nil, reason
			end

			sources[update.sourceId] = if empty(normalized) then nil else normalized
		else
			sources[update.sourceId] = nil
		end
	end

	local desired: Types.InputGraphSnapshot?, reason: string? = Validator.Compose(sources, previous)

	if desired == nil then
		return nil, reason
	end

	local contexts: { [string]: Types.ContextSnapshot } = table.clone(desired.contexts)

	for _, update in enabled do
		local context: Types.ContextSnapshot? = contexts[update.contextId]

		if context == nil then
			return nil, "UnknownContext"
		end

		local changed: Types.ContextSnapshot = table.clone(context)

		-- Public snapshots are read-only; construct the replacement explicitly.
		contexts[update.contextId] = table.freeze({
			id = changed.id,
			sourceId = changed.sourceId,
			priority = changed.priority,
			sink = changed.sink,
			enabled = update.enabled,
		})
	end

	local graph: Types.InputGraphSnapshot = table.freeze({
		generation = desired.generation,
		sources = desired.sources,
		inputs = desired.inputs,
		bindings = desired.bindings,
		recognition = desired.recognition,
		contexts = table.freeze(contexts),
	})

	return if Value.Equal(previous.sources, graph.sources) and Value.Equal(previous.contexts, graph.contexts)
		then previous
		else graph,
		nil
end

return Compiler
