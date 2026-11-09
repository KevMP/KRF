--!strict
local Types = require(script.Parent.types)
local InputTypes = require(script.Parent.Parent.Input.types)
local ActionTypes = require(script.Parent.Parent.Action.types)
local ActorTypes = require(script.Parent.Parent.Actor.types)
local InputLimits = require(script.Parent.Parent.Input.utils.InputConstants)
local RouteLimits = require(script.Parent.Parent.Action.utils.ActionRouteLimits)

export type Normalized = {
	inputs: { InputTypes.InputSourceUpdate },
	profiles: { ActionTypes.ProfileUpdate },
	contexts: { InputTypes.InputContextUpdate },
	selection: Types.ControlledActorChange?,
}

local Validator = {}

local function record(value: unknown, fields: { [string]: boolean }): { [string]: unknown }?
	if type(value) ~= "table" or getmetatable(value) ~= nil then
		return nil
	end

	for key in value :: { [unknown]: unknown } do
		if type(key) ~= "string" or not fields[key] then
			return nil
		end
	end

	return value :: { [string]: unknown }
end

local function array(value: unknown, maximum: number): { unknown }?
	if value == nil then
		return {}
	end

	if type(value) ~= "table" or getmetatable(value) ~= nil then
		return nil
	end

	local count: number = 0
	local length: number = #(value :: { unknown })

	for index in value :: { [unknown]: unknown } do
		if type(index) ~= "number" or index % 1 ~= 0 or index < 1 or index > length then
			return nil
		end

		count += 1

		if count > maximum then
			return nil
		end
	end

	return if count == length then value :: { unknown } else nil
end

function Validator.Normalize(value: unknown): (Normalized?, string?)
	local root = record(value, { inputs = true, profiles = true, contexts = true, selection = true })

	if root == nil then
		return nil, "InvalidControlChangeSet"
	end

	local inputValues = array(root.inputs, InputLimits.MAX_SOURCES * 2)
	local profileValues = array(root.profiles, RouteLimits.MAX_ACTORS * RouteLimits.MAX_SOURCES_PER_ACTOR * 2)
	local contextValues = array(root.contexts, InputLimits.MAX_CONTEXTS * 2)

	if inputValues == nil or profileValues == nil or contextValues == nil then
		return nil, "InvalidControlChangeSet"
	end

	local result: Normalized = { inputs = {}, profiles = {}, contexts = {} }
	local inputKeys: { [string]: boolean } = {}
	local profileKeys: { [ActorTypes.ActorView]: { [string]: boolean } } = {}
	local contextKeys: { [string]: boolean } = {}

	local function normalizeInput(item: unknown): string?
		local change = record(item, { kind = true, sourceId = true, definition = true })

		if change == nil or (change.kind ~= "Set" and change.kind ~= "Remove") then
			return "InvalidControlChangeSet"
		end

		if
			(change.kind == "Set" and change.definition == nil)
			or (change.kind == "Remove" and change.definition ~= nil)
		then
			return "InvalidControlChangeSet"
		end

		if type(change.sourceId) ~= "string" or #change.sourceId == 0 then
			return "InvalidSourceId"
		end

		if inputKeys[change.sourceId] then
			return "DuplicateInputSourceChange"
		end

		inputKeys[change.sourceId] = true

		table.insert(
			result.inputs,
			{ sourceId = change.sourceId, definition = change.definition :: InputTypes.InputSourceDefinition? }
		)

		return nil
	end

	local inputsRejection: string? = nil

	for _, item in inputValues do
		local reason: string? = normalizeInput(item)

		if reason ~= nil and (inputsRejection == nil or reason < inputsRejection) then
			inputsRejection = reason
		end
	end

	if inputsRejection ~= nil then
		return nil, inputsRejection
	end

	local function normalizeProfile(item: unknown): string?
		local change = record(item, { kind = true, sourceId = true, actor = true, profile = true })

		if change == nil or change.actor == nil or (change.kind ~= "Set" and change.kind ~= "Remove") then
			return "InvalidControlChangeSet"
		end

		if (change.kind == "Set" and change.profile == nil) or (change.kind == "Remove" and change.profile ~= nil) then
			return "InvalidControlChangeSet"
		end

		if type(change.actor) ~= "table" then
			return "ActorViewUnavailable"
		end

		if type(change.sourceId) ~= "string" or #change.sourceId == 0 then
			return "InvalidProfileSourceId"
		end

		local actor: ActorTypes.ActorView = change.actor :: ActorTypes.ActorView
		local keys: { [string]: boolean } = profileKeys[actor] or {}

		profileKeys[actor] = keys

		if keys[change.sourceId] then
			return "DuplicateProfileSourceChange"
		end

		keys[change.sourceId] = true

		table.insert(
			result.profiles,
			{ actor = actor, sourceId = change.sourceId, profile = change.profile :: ActionTypes.ControlProfile? }
		)

		return nil
	end

	local profilesRejection: string? = nil

	for _, item in profileValues do
		local reason: string? = normalizeProfile(item)

		if reason ~= nil and (profilesRejection == nil or reason < profilesRejection) then
			profilesRejection = reason
		end
	end

	if profilesRejection ~= nil then
		return nil, profilesRejection
	end

	local function normalizeContext(item: unknown): string?
		local change = record(item, { contextId = true, enabled = true })

		if
			change == nil
			or type(change.contextId) ~= "string"
			or #change.contextId == 0
			or type(change.enabled) ~= "boolean"
		then
			return "InvalidControlChangeSet"
		end

		if contextKeys[change.contextId] then
			return "DuplicateContextChange"
		end

		contextKeys[change.contextId] = true
		table.insert(result.contexts, { contextId = change.contextId, enabled = change.enabled })

		return nil
	end

	local contextsRejection: string? = nil

	for _, item in contextValues do
		local reason: string? = normalizeContext(item)

		if reason ~= nil and (contextsRejection == nil or reason < contextsRejection) then
			contextsRejection = reason
		end
	end

	if contextsRejection ~= nil then
		return nil, contextsRejection
	end

	if root.selection ~= nil then
		local selection = record(root.selection, { kind = true, actor = true })

		if selection == nil or selection.kind ~= "Set" then
			return nil, "InvalidControlChangeSet"
		end

		if selection.actor ~= nil and type(selection.actor) ~= "table" then
			return nil, "ActorViewUnavailable"
		end

		result.selection = { kind = "Set", actor = selection.actor :: ActorTypes.ActorView? }
	end

	table.sort(result.inputs, function(left: InputTypes.InputSourceUpdate, right: InputTypes.InputSourceUpdate): boolean
		return left.sourceId < right.sourceId
	end)

	table.sort(result.profiles, function(left: ActionTypes.ProfileUpdate, right: ActionTypes.ProfileUpdate): boolean
		return left.sourceId < right.sourceId
	end)

	table.sort(
		result.contexts,
		function(left: InputTypes.InputContextUpdate, right: InputTypes.InputContextUpdate): boolean
			return left.contextId < right.contextId
		end
	)

	return result, nil
end

return Validator
