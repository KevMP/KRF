--!strict
local Types = require(script.Parent.Parent.types)
local Constants = require(script.Parent.InputConstants)
local Validation = require(script.Parent.InputRecognitionValidation)
local Definitions = {}
local stepKinds = { Pressed = true, Tap = true, Held = true, LongHeld = true, DoubleTapped = true }

local function steps(raw: any, maximum: number): { Types.SequenceStep }?
	if not Validation.Array(raw, maximum) or #raw == 0 then
		return nil
	end

	local result: { Types.SequenceStep } = {}

	for _, step: any in raw do
		if type(step) == "string" then
			if not Validation.Id(step) then
				return nil
			end

			table.insert(result, step)
		elseif
			Validation.Fields(step, { inputId = true, kind = true })
			and Validation.Id(step.inputId)
			and stepKinds[step.kind]
		then
			local owned: any = { inputId = step.inputId, kind = step.kind }
			table.insert(result, table.freeze(owned) :: Types.InputSequenceStep)
		elseif
			Validation.Fields(step, { recognizerId = true, kind = true })
			and Validation.Id(step.recognizerId)
			and step.kind == "Custom"
		then
			local owned: any = { recognizerId = step.recognizerId, kind = "Custom" }
			table.insert(result, table.freeze(owned) :: Types.CustomSequenceStep)
		else
			return nil
		end
	end

	return table.freeze(result)
end

local function watched(raw: any): { Types.WatchedToken }?
	if raw == nil or (Validation.Array(raw, Constants.MAX_SEQUENCE_STEPS) and #raw == 0) then
		local empty: { Types.WatchedToken } = {}

		return table.freeze(empty)
	end

	local normalized: { Types.SequenceStep }? = steps(raw, Constants.MAX_SEQUENCE_STEPS)

	if normalized == nil then
		return nil
	end

	local result: { Types.WatchedToken } = {}
	local seen: { [string]: boolean } = {}

	for _, step: Types.SequenceStep in normalized do
		if type(step) == "string" then
			return nil
		end

		local key: string = Validation.TokenKey(step)

		if not seen[key] then
			table.insert(result, step)
			seen[key] = true
		end
	end

	table.sort(result, function(left: Types.WatchedToken, right: Types.WatchedToken): boolean
		return Validation.TokenKey(left) < Validation.TokenKey(right)
	end)

	return table.freeze(result)
end

function Definitions.NormalizeGroups(raw: any): ({ [string]: Types.SequenceGroupDefinition }?, string?)
	if raw == nil then
		local empty: { [string]: Types.SequenceGroupDefinition } = {}

		return table.freeze(empty), nil
	end

	if not Validation.Plain(raw) then
		return nil, "InvalidSequenceGroup"
	end

	local result: { [string]: Types.SequenceGroupDefinition } = {}
	local count: number = 0

	for id: any, definition: any in raw do
		count += 1

		if count > Constants.MAX_SEQUENCE_GROUPS then
			return nil, "InputSequenceGroupLimitExceeded"
		end

		if
			not Validation.Id(id)
			or not Validation.Fields(
				definition,
				{ policy = true, maxGapSeconds = true, maxTotalSeconds = true, scope = true, watchedTokens = true }
			)
		then
			return nil, "InvalidSequenceGroup"
		end

		local scope: { string }? = Validation.CopyIds(definition.scope, Constants.MAX_INPUTS)
		local tokens: { Types.WatchedToken }? = watched(definition.watchedTokens)

		if
			definition.policy ~= "DeferredPrefix"
			or not Validation.Duration(definition.maxGapSeconds)
			or not Validation.Duration(definition.maxTotalSeconds)
			or scope == nil
			or tokens == nil
		then
			return nil, "InvalidSequenceGroup"
		end

		local owned: any = {
			policy = "DeferredPrefix" :: "DeferredPrefix",
			maxGapSeconds = definition.maxGapSeconds,
			maxTotalSeconds = definition.maxTotalSeconds,
			scope = scope,
			watchedTokens = tokens,
		}

		result[id] = table.freeze(owned) :: Types.SequenceGroupDefinition
	end

	return table.freeze(result), nil
end

function Definitions.Normalize(raw: any): ({ [string]: Types.SequenceDefinition }?, string?)
	if raw == nil then
		local empty: { [string]: Types.SequenceDefinition } = {}

		return table.freeze(empty), nil
	end

	if not Validation.Plain(raw) then
		return nil, "InvalidSequence"
	end

	local result: { [string]: Types.SequenceDefinition } = {}
	local count: number = 0

	for id: any, definition: any in raw do
		count += 1

		if count > Constants.MAX_SEQUENCES then
			return nil, "InputSequenceLimitExceeded"
		end

		if
			not Validation.Id(id)
			or not Validation.Fields(definition, {
				steps = true,
				maxGapSeconds = true,
				maxTotalSeconds = true,
				scope = true,
				watchedTokens = true,
				exclusiveGroup = true,
			})
		then
			return nil, "InvalidSequence"
		end

		if Validation.Plain(definition.steps) and #definition.steps > Constants.MAX_SEQUENCE_STEPS then
			return nil, "InputSequenceStepLimitExceeded"
		end

		local normalized: { Types.SequenceStep }? = steps(definition.steps, Constants.MAX_SEQUENCE_STEPS)
		local tokens: { Types.WatchedToken }? = watched(definition.watchedTokens)

		local scope: { string }? = if definition.scope ~= nil
			then Validation.CopyIds(definition.scope, Constants.MAX_INPUTS)
			else nil

		if normalized == nil or tokens == nil or (definition.scope ~= nil and scope == nil) then
			return nil, "InvalidSequence"
		end

		if definition.exclusiveGroup ~= nil then
			if
				not Validation.Id(definition.exclusiveGroup)
				or definition.maxGapSeconds ~= nil
				or definition.maxTotalSeconds ~= nil
				or definition.scope ~= nil
				or definition.watchedTokens ~= nil
			then
				return nil, "InvalidSequenceGroup"
			end
		elseif
			not Validation.Duration(definition.maxGapSeconds) or not Validation.Duration(definition.maxTotalSeconds)
		then
			return nil, "InvalidSequence"
		end

		local owned: any = {
			steps = normalized,
			maxGapSeconds = definition.maxGapSeconds,
			maxTotalSeconds = definition.maxTotalSeconds,
			scope = scope,
			watchedTokens = if definition.exclusiveGroup ~= nil then nil else tokens,
			exclusiveGroup = definition.exclusiveGroup,
		}

		result[id] = table.freeze(owned) :: Types.SequenceDefinition
	end

	return table.freeze(result), nil
end

return Definitions
