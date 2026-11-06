--!strict
local Types = require(script.Parent.Parent.types)
local Constants = require(script.Parent.InputConstants)
local Validation = require(script.Parent.InputRecognitionValidation)
local Value = require(script.Parent.InputValue)
local Recognizers = require(script.Parent.InputRecognizerDefinitions)
local Compiler = {}

local function append(index: { [string]: { string } }, key: string, id: string): ()
	local ids: { string } = index[key] or {}

	index[key] = ids

	if table.find(ids, id) == nil then
		table.insert(ids, id)
	end
end

function Compiler.Compile(
	sources: { [string]: Types.InputSourceDefinition },
	inputs: { [string]: Types.InputSnapshot }
): (Types.RecognitionCatalog?, string?)
	local recognizers: { [string]: Types.RecognizerSnapshot }?, reason: string? = Recognizers.Compose(sources, inputs)

	if recognizers == nil then
		return nil, reason
	end

	local gestures: { [string]: unknown } = {}

	for sourceId: string, source: Types.InputSourceDefinition in sources do
		for inputId: string, definitions: Types.GestureDefinitions in source.gestures or {} do
			for kind: string, definition: any in definitions :: any do
				gestures[Validation.InputKey(inputId, kind)] =
					table.freeze({ sourceId = sourceId, definition = definition })
			end
		end
	end

	local sequences: { [string]: Types.SequenceSnapshot } = {}
	local machines: { [string]: Types.SequenceMachine } = {}
	local machineIndex: { [string]: { string } } = {}
	local recognizerIndex: { [string]: { string } } = {}
	local sequenceCount: number = 0
	local groupCount: number = 0
	local recognizerDependencies: { [string]: { [string]: unknown } } = {}
	local scopedKeys: { [string]: { [string]: string } } = {}
	local gestureStepInputs: { [string]: { [string]: boolean } } = {}

	local function token(step: Types.SequenceStep, machine: Types.SequenceMachine): (string?, string?)
		if type(step) ~= "string" and step.kind == "Custom" then
			local custom: Types.RecognizerSnapshot? = recognizers[step.recognizerId]

			if custom == nil then
				return nil, "UnknownSequenceRecognizer"
			end

			machine.recognizers[step.recognizerId] = true
			machine.dependencies[Validation.CustomKey(step.recognizerId)] = custom

			for _, inputId: string in custom.definition.inputs do
				machine.inputs[inputId] = true
			end

			for inputId: string, kinds: { Types.GestureKind } in custom.definition.gestures or {} do
				for _, kind: Types.GestureKind in kinds do
					machine.dependencies[Validation.InputKey(inputId, kind)] =
						gestures[Validation.InputKey(inputId, kind)]
				end
			end

			return Validation.TokenKey(step), nil
		end

		local inputId: string = if type(step) == "string" then step else step.inputId
		local kind: string = if type(step) == "string" then "Pressed" else step.kind
		local input: Types.InputSnapshot? = inputs[inputId]

		if input == nil then
			return nil, "UnknownSequenceInput"
		end

		if input.inputType ~= Enum.InputActionType.Bool then
			return nil, "SequenceRequiresBool"
		end

		machine.inputs[inputId] = true

		local key: string = Validation.InputKey(inputId, kind)

		if kind ~= "Pressed" then
			if gestures[key] == nil then
				return nil, "UnknownSequenceGesture"
			end

			machine.dependencies[key] = gestures[key]
		end

		return key, nil
	end

	for _, sourceId: string in Value.Keys(sources) do
		local source: Types.InputSourceDefinition = sources[sourceId]

		for _ in source.sequenceGroups or {} do
			groupCount += 1
		end

		if groupCount > Constants.MAX_SEQUENCE_GROUPS then
			return nil, "InputSequenceGroupLimitExceeded"
		end

		local groupMembers: { [string]: { { string } } } = {}

		for _, id: string in Value.Keys(source.sequences or {}) do
			local definition: Types.SequenceDefinition = (source.sequences or {})[id]

			if sequences[id] ~= nil then
				return nil, "DuplicateSequenceOwner"
			end

			sequenceCount += 1

			if sequenceCount > Constants.MAX_SEQUENCES then
				return nil, "InputSequenceLimitExceeded"
			end

			sequences[id] = table.freeze({ sequenceId = id, sourceId = sourceId, definition = definition })

			local group: Types.SequenceGroupDefinition? = if definition.exclusiveGroup ~= nil
				then (source.sequenceGroups or {})[definition.exclusiveGroup]
				else nil

			if definition.exclusiveGroup ~= nil and group == nil then
				return nil, "InvalidSequenceGroup"
			end

			local machineId: string = if group ~= nil
				then "G" .. tostring(#sourceId) .. ":" .. sourceId .. (definition.exclusiveGroup or "")
				else "S" .. id

			if machines[machineId] == nil then
				local created: Types.SequenceMachine = {
					id = machineId,
					sourceId = sourceId,
					deferred = group ~= nil,
					nodes = { { edges = {}, completed = {} } },
					inputs = {},
					recognizers = {},
					dependencies = {},
					watched = {},
					maxGapSeconds = if group ~= nil
						then group.maxGapSeconds
						else assert(definition.maxGapSeconds, "Expected gap"),
					maxTotalSeconds = if group ~= nil
						then group.maxTotalSeconds
						else assert(definition.maxTotalSeconds, "Expected total"),
				}

				machines[machineId] = created
				scopedKeys[machineId] = {}
				gestureStepInputs[machineId] = {}
			end

			local machine: Types.SequenceMachine = machines[machineId]

			local keys: { string } = {}
			local nodeIndex: number = 1

			for _, step: Types.SequenceStep in definition.steps do
				local key: string?, failure: string? = token(step, machine)

				if key == nil then
					return nil, failure
				end

				table.insert(keys, key)
				machine.watched[key] = true

				if type(step) ~= "string" and step.kind ~= "Custom" and step.kind ~= "Pressed" then
					gestureStepInputs[machineId][step.inputId] = true
				end

				local node: Types.SequenceNode = machine.nodes[nodeIndex]
				local child: number? = node.edges[key]

				if child == nil then
					child = #machine.nodes + 1
					node.edges[key] = child

					local createdNode: Types.SequenceNode = { edges = {}, completed = {} }
					table.insert(machine.nodes, createdNode)
				end

				nodeIndex = assert(child, "Expected compiled child")
			end

			table.insert(machine.nodes[nodeIndex].completed, id)

			if definition.exclusiveGroup ~= nil then
				local members = groupMembers[definition.exclusiveGroup] or {}

				groupMembers[definition.exclusiveGroup] = members
				table.insert(members, keys)
			end

			local scope: { string }? = if group ~= nil then group.scope else definition.scope

			for _, inputId: string in scope or {} do
				local key: string?, failure: string? = token(inputId, machine)

				if key == nil then
					return nil, failure
				end

				scopedKeys[machineId][key] = inputId
			end

			for _, step: Types.WatchedToken in
				(if group ~= nil then group.watchedTokens else definition.watchedTokens) or {}
			do
				local key: string?, failure: string? = token(step, machine)

				if key == nil then
					return nil, failure
				end

				machine.watched[key] = true
			end
		end

		for name in source.sequenceGroups or {} do
			local members: { { string } }? = groupMembers[name]

			if members == nil or #members < 2 then
				return nil, "InvalidSequenceGroup"
			end

			table.sort(members, function(left: { string }, right: { string }): boolean
				return #left < #right
			end)

			local shortest: { string } = members[1]
			local proper: boolean = false

			for _, keys: { string } in members do
				for position: number, key: string in shortest do
					if keys[position] ~= key then
						return nil, "InvalidSequenceGroup"
					end
				end

				proper = proper or #keys > #shortest
			end

			if not proper then
				return nil, "InvalidSequenceGroup"
			end
		end
	end

	for _, id: string in Value.Keys(machines) do
		local machine: Types.SequenceMachine = machines[id]

		-- Pressing an input is how its gesture step begins, not an interruption.
		for key: string, inputId: string in scopedKeys[id] do
			if not gestureStepInputs[id][inputId] then
				machine.watched[key] = true
			end
		end

		for key in machine.watched do
			append(machineIndex, key, id)
		end

		for _, node: Types.SequenceNode in machine.nodes do
			table.sort(node.completed)
			table.freeze(node.edges)
			table.freeze(node.completed)
			table.freeze(node)
		end

		table.freeze(machine.nodes)
		table.freeze(machine.watched)
		table.freeze(machine.inputs)
		table.freeze(machine.recognizers)
		table.freeze(machine.dependencies)
		table.freeze(machine)
	end

	for _, id: string in Value.Keys(recognizers) do
		local definition: Types.RecognizerDefinition = recognizers[id].definition

		for _, inputId: string in definition.inputs do
			for _, kind: string in { "Pressed", "Released", "Cancelled", "StateChanged" } do
				append(recognizerIndex, Validation.InputKey(inputId, kind), id)
			end
		end

		local dependencies: { [string]: unknown } = {}

		recognizerDependencies[id] = dependencies

		for inputId: string, kinds: { Types.GestureKind } in definition.gestures or {} do
			for _, kind: Types.GestureKind in kinds do
				local key: string = Validation.InputKey(inputId, kind)

				dependencies[key] = gestures[key]
				append(recognizerIndex, key, id)
			end
		end
	end

	for _, dependencies in recognizerDependencies do
		table.freeze(dependencies)
	end

	table.freeze(recognizerDependencies)

	for _, index in { machineIndex, recognizerIndex } do
		for _, ids in index do
			table.freeze(ids)
		end

		table.freeze(index)
	end

	local catalog: Types.RecognitionCatalog = {
		sequences = table.freeze(sequences),
		recognizers = recognizers,
		machines = table.freeze(machines),
		machineIndex = machineIndex,
		recognizerIndex = recognizerIndex,
		recognizerDependencies = recognizerDependencies,
	}

	return table.freeze(catalog) :: Types.RecognitionCatalog, nil
end

return Compiler
