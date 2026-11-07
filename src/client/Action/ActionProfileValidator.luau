--!strict
local Types = require(script.Parent.types)
local InputTypes = require(script.Parent.Parent.Input.types)
local Identity = require(script.Parent.utils.ActionRouteIdentity)
local Limits = require(script.Parent.utils.ActionRouteLimits)

export type ValidatedRoute = {
	read when: Types.RouteKey,
	read target: Types.RouteTarget,
	read requiredContexts: { string },
	read dispatch: { read mode: Types.DispatchMode, read priority: number },
}

export type Profile = { read priority: number, read routes: { ValidatedRoute } }

local Validator = {}

function Validator.Priority(value: any): boolean
	return type(value) == "number" and value == value and math.abs(value) <= Limits.MAX_PRIORITY and value % 1 == 0
end

local function array(value: any, limit: number): (boolean, boolean)
	if not Identity.Plain(value) then
		return false, false
	end

	local count: number = 0

	for index in value do
		count += 1

		if count > limit then
			return false, true
		end

		if type(index) ~= "number" or index % 1 ~= 0 or index < 1 then
			return false, false
		end
	end

	return count == #value, false
end

Validator.IsArray = array

function Validator.Reference(key: Types.RouteKey, contexts: { string }, graph: InputTypes.InputGraphSnapshot): string?
	if key.kind == "Input" then
		local input: InputTypes.InputSnapshot? = graph.inputs[key.inputId]

		if input == nil then
			return "UnknownRouteInput"
		end

		if input.inputType ~= Enum.InputActionType.Bool then
			return "RouteInputNotBool"
		end

		if key.gesture ~= "Pressed" then
			local found: boolean = false

			for _, source: InputTypes.InputSourceDefinition in graph.sources do
				local gestures: InputTypes.GestureDefinitions? = if source.gestures ~= nil
					then source.gestures[key.inputId]
					else nil

				if
					gestures ~= nil
					and (
						(key.gesture == "Tap" and gestures.Tap ~= nil)
						or (key.gesture == "Held" and gestures.Held ~= nil)
						or (key.gesture == "LongHeld" and gestures.LongHeld ~= nil)
						or (key.gesture == "DoubleTapped" and gestures.DoubleTapped ~= nil)
					)
				then
					found = true
					break
				end
			end

			if not found then
				return "UnknownRouteGesture"
			end
		end
	elseif key.kind == "Sequence" then
		if graph.recognition == nil or graph.recognition.sequences[key.sequenceId] == nil then
			return "UnknownRouteSequence"
		end
	elseif graph.recognition == nil or graph.recognition.recognizers[key.recognizerId] == nil then
		return "UnknownRouteRecognizer"
	end

	for _, contextId: string in contexts do
		if graph.contexts[contextId] == nil then
			return "UnknownRouteContext"
		end
	end

	return nil
end

local function route(value: any, graph: InputTypes.InputGraphSnapshot): (ValidatedRoute?, string?)
	if not Identity.Plain(value, { when = true, target = true, requiredContexts = true, dispatch = true }) then
		return nil, "InvalidActionRoute"
	end

	local key: Types.RouteKey? = Identity.Key(value.when)

	if key == nil then
		return nil, "InvalidRouteKey"
	end

	local target: any = value.target

	if not Identity.Plain(target) then
		return nil, "InvalidRouteTarget"
	end

	local targetKind: any = rawget(target, "kind")
	local actionId: any = rawget(target, "actionId")
	local resolver: any = rawget(target, "resolve")
	local normalizedTarget: Types.RouteTarget

	if targetKind == "Fixed" and Identity.Plain(target, { kind = true, actionId = true }) then
		if not Identity.IsId(actionId) then
			return nil, "InvalidActionId"
		end

		normalizedTarget = table.freeze({ kind = "Fixed", actionId = actionId :: string }) :: Types.RouteTarget
	elseif
		targetKind == "Dynamic"
		and Identity.Plain(target, { kind = true, resolve = true })
		and type(resolver) == "function"
	then
		normalizedTarget = table.freeze({ kind = "Dynamic", resolve = resolver }) :: Types.RouteTarget
	else
		return nil, "InvalidRouteTarget"
	end

	local contexts: { string } = {}

	if value.requiredContexts ~= nil then
		local valid: boolean, overflow: boolean =
			array(value.requiredContexts, Limits.MAX_REQUIRED_CONTEXT_DECLARATIONS)

		if not valid then
			return nil, if overflow then "RouteContextLimitExceeded" else "InvalidRequiredContexts"
		end

		local seen: { [string]: boolean } = {}

		for _, id in value.requiredContexts do
			if not Identity.IsId(id) then
				return nil, "InvalidRequiredContexts"
			end

			if not seen[id] then
				seen[id] = true
				table.insert(contexts, id)
			end

			if #contexts > Limits.MAX_REQUIRED_CONTEXTS then
				return nil, "RouteContextLimitExceeded"
			end
		end

		table.sort(contexts)
	end

	local mode: Types.DispatchMode = if key.kind == "Sequence" then "Exclusive" else "Independent"
	local priority: number = 0

	if value.dispatch ~= nil then
		if not Identity.Plain(value.dispatch, { mode = true, priority = true }) then
			return nil, "InvalidDispatchPolicy"
		end

		if value.dispatch.mode ~= nil then
			if value.dispatch.mode ~= "Exclusive" and value.dispatch.mode ~= "Independent" then
				return nil, "InvalidDispatchPolicy"
			end

			mode = value.dispatch.mode
		end

		if value.dispatch.priority ~= nil then
			if not Validator.Priority(value.dispatch.priority) then
				return nil, "InvalidDispatchPolicy"
			end

			priority = value.dispatch.priority
		end
	end

	local rejection: string? = Validator.Reference(key, contexts, graph)

	if rejection ~= nil then
		return nil, rejection
	end

	return table.freeze({
		when = key,
		target = normalizedTarget,
		requiredContexts = table.freeze(contexts),
		dispatch = table.freeze({ mode = mode, priority = priority }),
	}),
		nil
end

function Validator.Normalize(value: any, graph: InputTypes.InputGraphSnapshot): (Profile?, string?)
	if not Identity.Plain(value, { priority = true, routes = true }) then
		return nil, "InvalidControlProfile"
	end

	local priority: any = if value.priority == nil then 0 else value.priority

	if not Validator.Priority(priority) then
		return nil, "InvalidProfilePriority"
	end

	local valid: boolean, overflow: boolean = array(value.routes, Limits.MAX_ROUTES_PER_SOURCE)

	if not valid then
		return nil, if overflow then "ProfileRouteLimitExceeded" else "InvalidControlProfile"
	end

	local routes: { ValidatedRoute } = {}
	local seen: { [string]: boolean } = {}

	for _, declaration in value.routes do
		local normalized: ValidatedRoute?, reason: string? = route(declaration, graph)

		if normalized == nil then
			return nil, reason
		end

		local canonical: string = Identity.Canonical(normalized.when)

		if seen[canonical] then
			return nil, "DuplicateRouteKey"
		end

		seen[canonical] = true
		table.insert(routes, normalized)
	end

	table.sort(routes, function(left: ValidatedRoute, right: ValidatedRoute): boolean
		return Identity.Canonical(left.when) < Identity.Canonical(right.when)
	end)

	return table.freeze({ priority = priority, routes = table.freeze(routes) }), nil
end

return Validator
