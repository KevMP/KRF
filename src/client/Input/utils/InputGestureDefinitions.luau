--!strict
local Types = require(script.Parent.Parent.types)
local Constants = require(script.Parent.InputConstants)
local Value = require(script.Parent.InputValue)

local Definitions = {}
local kinds = { Tap = true, Held = true, LongHeld = true, DoubleTapped = true }
local tapFields = { maxDurationSeconds = true, suppressIfHoldRecognized = true }
local holdFields = { afterSeconds = true }
local doubleFields = { maxTapDurationSeconds = true, maxGapSeconds = true, arbitration = true }

local function fields(value: any, allowed: { [string]: boolean }): boolean
	if type(value) ~= "table" or getmetatable(value) ~= nil then
		return false
	end

	for key in value do
		if allowed[key] ~= true then
			return false
		end
	end

	return true
end

local function duration(value: any): boolean
	return Value.IsFinite(value) and value > 0 and value <= Constants.MAX_GESTURE_DURATION_SECONDS
end

function Definitions.Normalize(raw: any): ({ [string]: Types.GestureDefinitions }?, string?)
	if raw == nil then
		local empty: { [string]: Types.GestureDefinitions } = {}

		return table.freeze(empty), nil
	end

	if type(raw) ~= "table" or getmetatable(raw) ~= nil then
		return nil, "InvalidGesture"
	end

	local result: { [string]: Types.GestureDefinitions } = {}
	local total: number = 0

	for inputId: any, definitions: any in raw do
		if type(inputId) ~= "string" or #inputId == 0 or not fields(definitions, kinds) or next(definitions) == nil then
			return nil, "InvalidGesture"
		end

		local owned: any = {}

		for kind: string, definition: any in definitions do
			total += 1

			if total > Constants.MAX_GESTURES then
				return nil, "InputGestureLimitExceeded"
			end

			if kind == "Tap" then
				if
					not fields(definition, tapFields)
					or not duration(definition.maxDurationSeconds)
					or (
						definition.suppressIfHoldRecognized ~= nil
						and type(definition.suppressIfHoldRecognized) ~= "boolean"
					)
				then
					return nil, "InvalidGesture"
				end

				owned.Tap = table.freeze({
					maxDurationSeconds = definition.maxDurationSeconds,
					suppressIfHoldRecognized = definition.suppressIfHoldRecognized == true,
				})
			elseif kind == "DoubleTapped" then
				if
					not fields(definition, doubleFields)
					or not duration(definition.maxTapDurationSeconds)
					or not duration(definition.maxGapSeconds)
				then
					return nil, "InvalidGesture"
				end

				local policy: any = if definition.arbitration == nil then "PreferSpecific" else definition.arbitration

				if policy ~= "PreferSpecific" and policy ~= "Independent" and policy ~= "DeferredTap" then
					return nil, "InvalidGesturePolicy"
				end

				owned.DoubleTapped = table.freeze({
					maxTapDurationSeconds = definition.maxTapDurationSeconds,
					maxGapSeconds = definition.maxGapSeconds,
					arbitration = policy,
				})
			else
				if not fields(definition, holdFields) or not duration(definition.afterSeconds) then
					return nil, "InvalidGesture"
				end

				owned[kind] = table.freeze({ afterSeconds = definition.afterSeconds })
			end
		end

		if owned.Tap ~= nil and owned.Tap.suppressIfHoldRecognized and owned.Held == nil and owned.LongHeld == nil then
			return nil, "GestureHoldDependencyMissing"
		end

		if owned.DoubleTapped ~= nil and owned.DoubleTapped.arbitration == "DeferredTap" then
			if
				owned.Tap == nil
				or owned.Tap.suppressIfHoldRecognized
				or owned.Tap.maxDurationSeconds ~= owned.DoubleTapped.maxTapDurationSeconds
			then
				return nil, "InvalidDeferredTapPair"
			end
		end

		result[inputId] = table.freeze(owned) :: Types.GestureDefinitions
	end

	return table.freeze(result), nil
end

function Definitions.Compose(
	sources: { [string]: Types.InputSourceDefinition },
	inputs: { [string]: Types.InputSnapshot }
): (boolean, string?)
	local combined: { [string]: { [string]: any } } = {}
	local total: number = 0

	for _, sourceId: string in Value.Keys(sources) do
		for inputId: string, definitions: Types.GestureDefinitions in sources[sourceId].gestures or {} do
			local input: Types.InputSnapshot? = inputs[inputId]

			if input == nil then
				return false, "UnknownGestureInput"
			end

			if input.inputType ~= Enum.InputActionType.Bool then
				return false, "GestureRequiresBool"
			end

			local merged = combined[inputId] or {}

			combined[inputId] = merged

			for kind: string, definition in definitions :: any do
				total += 1

				if total > Constants.MAX_GESTURES then
					return false, "InputGestureLimitExceeded"
				end

				if merged[kind] ~= nil then
					return false, "DuplicateGestureOwner"
				end

				merged[kind] = definition
			end
		end
	end

	for _, definitions in combined do
		local held: Types.HoldDefinition? = definitions.Held
		local longHeld: Types.HoldDefinition? = definitions.LongHeld

		if held ~= nil and longHeld ~= nil and held.afterSeconds >= longHeld.afterSeconds then
			return false, "InvalidHoldThresholdOrder"
		end
	end

	return true, nil
end

return Definitions
