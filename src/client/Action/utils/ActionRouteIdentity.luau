--!strict
local Types = require(script.Parent.Parent.types)
local InputTypes = require(script.Parent.Parent.Parent.Input.types)
local Limits = require(script.Parent.ActionRouteLimits)
local Identity = {}

function Identity.IsId(value: any): boolean
	return type(value) == "string" and #value > 0 and #value <= Limits.MAX_ID_BYTES
end

function Identity.Plain(value: any, fields: { [string]: boolean }?): boolean
	if type(value) ~= "table" or getmetatable(value) ~= nil then
		return false
	end

	if fields ~= nil then
		for field in value do
			if not fields[field] then
				return false
			end
		end
	end

	return true
end

function Identity.Key(value: any): Types.RouteKey?
	if not Identity.Plain(value) then
		return nil
	end

	if value.kind == "Input" then
		if
			not Identity.Plain(value, { kind = true, inputId = true, gesture = true })
			or not Identity.IsId(value.inputId)
		then
			return nil
		end

		local gesture = value.gesture

		if
			gesture ~= "Pressed"
			and gesture ~= "Tap"
			and gesture ~= "Held"
			and gesture ~= "LongHeld"
			and gesture ~= "DoubleTapped"
		then
			return nil
		end

		return table.freeze({ kind = "Input", inputId = value.inputId, gesture = gesture }) :: Types.RouteKey
	elseif
		value.kind == "Sequence"
		and Identity.Plain(value, { kind = true, sequenceId = true })
		and Identity.IsId(value.sequenceId)
	then
		return table.freeze({ kind = "Sequence", sequenceId = value.sequenceId }) :: Types.RouteKey
	elseif
		value.kind == "Custom"
		and Identity.Plain(value, { kind = true, recognizerId = true })
		and Identity.IsId(value.recognizerId)
	then
		return table.freeze({ kind = "Custom", recognizerId = value.recognizerId }) :: Types.RouteKey
	end

	return nil
end

function Identity.Canonical(key: Types.RouteKey): string
	if key.kind == "Input" then
		return string.format("I%d:%s:%s", #key.inputId, key.inputId, key.gesture)
	end

	if key.kind == "Sequence" then
		return "S" .. key.sequenceId
	end

	return "C" .. key.recognizerId
end

function Identity.Candidate(candidate: InputTypes.RecognitionCandidate): Types.RouteKey
	if candidate.kind == "Input" then
		return table.freeze({
			kind = "Input",
			inputId = candidate.inputId,
			gesture = candidate.gesture,
		}) :: Types.RouteKey
	end

	if candidate.kind == "Sequence" then
		return table.freeze({ kind = "Sequence", sequenceId = candidate.sequenceId }) :: Types.RouteKey
	end

	return table.freeze({ kind = "Custom", recognizerId = candidate.recognizerId }) :: Types.RouteKey
end

return Identity
