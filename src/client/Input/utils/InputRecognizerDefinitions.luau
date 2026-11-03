--!strict
local Types = require(script.Parent.Parent.types)
local Constants = require(script.Parent.InputConstants)
local Validation = require(script.Parent.InputRecognitionValidation)
local Value = require(script.Parent.InputValue)
local Definitions = {}
local kinds = { Tap = true, Held = true, LongHeld = true, DoubleTapped = true }

function Definitions.Normalize(raw: any): ({ [string]: Types.RecognizerDefinition }?, string?)
	if raw == nil then
		local empty: { [string]: Types.RecognizerDefinition } = {}

		return table.freeze(empty), nil
	end

	if not Validation.Plain(raw) then
		return nil, "InvalidRecognizer"
	end

	local result: { [string]: Types.RecognizerDefinition } = {}
	local count: number = 0

	for id: any, definition: any in raw do
		count += 1

		if count > Constants.MAX_RECOGNIZERS then
			return nil, "InputRecognizerLimitExceeded"
		end

		if
			not Validation.Id(id)
			or not Validation.Fields(
				definition,
				{ inputs = true, gestures = true, maxWindowSeconds = true, onEvent = true, onDeadline = true }
			)
		then
			return nil, "InvalidRecognizer"
		end

		if Validation.Plain(definition.inputs) and #definition.inputs > Constants.MAX_RECOGNIZER_INPUTS then
			return nil, "InputRecognizerInputLimitExceeded"
		end

		local inputs: { string }? = Validation.CopyIds(definition.inputs, Constants.MAX_RECOGNIZER_INPUTS)

		if
			inputs == nil
			or #inputs == 0
			or not Validation.Duration(definition.maxWindowSeconds)
			or type(definition.onEvent) ~= "function"
			or (definition.onDeadline ~= nil and type(definition.onDeadline) ~= "function")
		then
			return nil, "InvalidRecognizer"
		end

		if definition.gestures ~= nil and not Validation.Plain(definition.gestures) then
			return nil, "InvalidRecognizer"
		end

		local gestures: { [string]: { Types.GestureKind } } = {}

		for inputId: any, watched: any in definition.gestures or {} do
			if table.find(inputs, inputId) == nil or not Validation.Array(watched, 4) or #watched == 0 then
				return nil, "InvalidRecognizer"
			end

			local owned: { Types.GestureKind } = {}

			for _, kind: any in watched do
				if kinds[kind] ~= true or table.find(owned, kind) ~= nil then
					return nil, "InvalidRecognizer"
				end

				table.insert(owned, kind)
			end

			table.sort(owned)
			gestures[inputId] = table.freeze(owned)
		end

		local owned: any = {
			inputs = inputs,
			gestures = table.freeze(gestures),
			maxWindowSeconds = definition.maxWindowSeconds,
			onEvent = definition.onEvent,
			onDeadline = definition.onDeadline,
		}

		result[id] = table.freeze(owned) :: Types.RecognizerDefinition
	end

	return table.freeze(result), nil
end

function Definitions.Compose(
	sources: { [string]: Types.InputSourceDefinition },
	inputs: { [string]: Types.InputSnapshot }
): ({ [string]: Types.RecognizerSnapshot }?, string?)
	local result: { [string]: Types.RecognizerSnapshot } = {}
	local count: number = 0

	for _, sourceId: string in Value.Keys(sources) do
		for id: string, definition: Types.RecognizerDefinition in sources[sourceId].recognizers or {} do
			if result[id] ~= nil then
				return nil, "DuplicateRecognizerOwner"
			end

			count += 1

			if count > Constants.MAX_RECOGNIZERS then
				return nil, "InputRecognizerLimitExceeded"
			end

			for _, inputId: string in definition.inputs do
				if inputs[inputId] == nil then
					return nil, "UnknownRecognizerInput"
				end

				for _, kind: Types.GestureKind in (definition.gestures or {})[inputId] or {} do
					local found: boolean = false

					for _, source: Types.InputSourceDefinition in sources do
						local gestures: Types.GestureDefinitions? = (source.gestures or {})[inputId]

						if gestures ~= nil and (gestures :: any)[kind] ~= nil then
							found = true
							break
						end
					end

					if not found then
						return nil, "UnknownRecognizerGesture"
					end
				end
			end

			result[id] =
				table.freeze({ recognizerId = id, sourceId = sourceId, definition = definition, faulted = false })
		end
	end

	return table.freeze(result), nil
end

return Definitions
