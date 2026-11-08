--!strict
local Types = require(script.Parent.Parent.types)
local ActorTypes = require(script.Parent.Parent.Parent.Actor.types)
local InputTypes = require(script.Parent.Parent.Parent.Input.types)
local InputValue = require(script.Parent.Parent.Parent.Input.utils.InputValue)
local Observers = require(script.Parent.Parent.Parent.Parent.shared.Signal.PrivateObservers)
local Graph = require(script.Parent.ActionProfileGraph)
local Identity = require(script.Parent.ActionRouteIdentity)

-- Projects immutable old/new route validity and delivers it in order. Recognition
-- dependencies and epoch invalidation belong here rather than in profile
-- compilation or dispatch.
local Transitions = {}

local function recognitionDefinition(catalog: InputTypes.RecognitionCatalog?, key: Types.RouteKey): unknown
	if catalog == nil then
		return nil
	end

	if key.kind == "Sequence" then
		return catalog.sequenceMachines[key.sequenceId]
	end

	if key.kind == "Custom" then
		local recognizer: InputTypes.RecognizerSnapshot? = catalog.recognizers[key.recognizerId]

		return if recognizer ~= nil then recognizer.definition else nil
	end

	return nil
end

local function isInvalidated(
	key: Types.RouteKey,
	catalog: InputTypes.RecognitionCatalog?,
	invalidated: { [string]: any }
): boolean
	if key.kind == "Input" then
		return invalidated[key.inputId] ~= nil
	end

	if catalog == nil then
		return false
	end

	if key.kind == "Sequence" then
		local machine: InputTypes.SequenceMachine? = catalog.sequenceMachines[key.sequenceId]

		for inputId: string in if machine ~= nil then machine.inputs else {} do
			if invalidated[inputId] ~= nil then
				return true
			end
		end

		return false
	end

	local recognizer: InputTypes.RecognizerSnapshot? = catalog.recognizers[key.recognizerId]

	for _, inputId: string in if recognizer ~= nil then recognizer.definition.inputs else {} do
		if invalidated[inputId] ~= nil then
			return true
		end
	end

	return false
end

function Transitions.Diff(
	actor: ActorTypes.ActorView,
	before: Graph.Graph?,
	after: Graph.Graph?,
	oldInput: InputTypes.InputGraphSnapshot,
	newInput: InputTypes.InputGraphSnapshot,
	reason: string,
	invalidated: { [string]: any }?
): { Types.EffectiveRouteTransition }
	local union: { [string]: boolean } = {}

	for _, key: string in if before ~= nil then before.keys else {} do
		union[key] = true
	end

	for _, key: string in if after ~= nil then after.keys else {} do
		union[key] = true
	end

	local keys: { string } = {}

	for key: string in union do
		table.insert(keys, key)
	end

	table.sort(keys)
	local changes: { Types.EffectiveRouteTransition } = {}

	for _, key: string in keys do
		local previous: Types.RouteQuerySnapshot = Graph.Evaluate(before, key, oldInput)
		local nextSnapshot: Types.RouteQuerySnapshot = Graph.Evaluate(after, key, newInput)

		local entries: { Graph.Entry } = if after ~= nil and after.index[key] ~= nil
			then after.index[key]
			else assert(before, "Expected prior contribution").index[key]

		local routeKey: Types.RouteKey = entries[1].route.when

		local force: boolean = (invalidated ~= nil and isInvalidated(routeKey, oldInput.recognition, invalidated))
			or not InputValue.Equal(
				recognitionDefinition(oldInput.recognition, routeKey),
				recognitionDefinition(newInput.recognition, routeKey)
			)

		if force or not InputValue.Equal(previous, nextSnapshot) then
			table.insert(
				changes,
				table.freeze({
					actor = actor,
					key = routeKey,
					previous = previous,
					next = nextSnapshot,
					reason = reason,
					invalidated = if force then true else nil,
				})
			)
		end
	end

	return changes
end

function Transitions.DiffCatalogs(
	before: Graph.Catalog,
	after: Graph.Catalog,
	oldInput: InputTypes.InputGraphSnapshot,
	newInput: InputTypes.InputGraphSnapshot,
	reason: string,
	invalidated: { [string]: any }?
): { Types.EffectiveRouteTransition }
	local actors: Graph.Catalog = table.clone(before)
	local changes: { Types.EffectiveRouteTransition } = {}

	for actor: ActorTypes.ActorView, graph: Graph.Graph in after do
		actors[actor] = graph
	end

	for actor: ActorTypes.ActorView in actors do
		for _, change: Types.EffectiveRouteTransition in
			Transitions.Diff(actor, before[actor], after[actor], oldInput, newInput, reason, invalidated)
		do
			table.insert(changes, change)
		end
	end

	return changes
end

-- A transition raised during delivery is newer truth for its route, so it is
-- delivered immediately and the older one stops at the observers it has reached.
-- Other routes in the older batch are unaffected and still reach every observer.
function Transitions.Publisher(
	observers: Observers.Registry<(Types.EffectiveRouteTransition) -> ()>,
	report: (string) -> ()
): ({ Types.EffectiveRouteTransition }) -> ()
	local latest: { [ActorTypes.ActorView]: { [string]: number } } = {}
	local ordinal: number = 0
	local depth: number = 0

	return function(changes: { Types.EffectiveRouteTransition }): ()
		local stamps: { number } = {}

		depth += 1

		for position: number, change: Types.EffectiveRouteTransition in changes do
			local routes: { [string]: number } = latest[change.actor] or {}

			ordinal += 1
			latest[change.actor] = routes
			routes[Identity.Canonical(change.key)] = ordinal
			stamps[position] = ordinal
		end

		for position: number, change: Types.EffectiveRouteTransition in changes do
			local routes: { [string]: number } = latest[change.actor]
			local key: string = Identity.Canonical(change.key)

			for _, entry in observers.Snapshot() do
				if routes[key] ~= stamps[position] then
					break
				end

				if entry.active and not Observers.Run(entry.callback, change) then
					report("ActionRouteObserverFailed")
				end
			end
		end

		depth -= 1

		if depth == 0 then
			table.clear(latest)
		end
	end
end

return Transitions
