--!strict
local Types = require(script.Parent.Parent.types)
local ActorTypes = require(script.Parent.Parent.Parent.Actor.types)
local InputTypes = require(script.Parent.Parent.Parent.Input.types)
local InputValue = require(script.Parent.Parent.Parent.Input.utils.InputValue)
local Graph = require(script.Parent.ActionProfileGraph)

-- Projects immutable old/new route validity. Recognition dependencies and epoch
-- invalidation belong here rather than in profile compilation or dispatch.
local Transitions = {}

local function snapshotsEqual(left: Types.RouteQuerySnapshot, right: Types.RouteQuerySnapshot): boolean
	if left.status ~= right.status then
		return false
	end

	local leftSources: { string }
	local rightSources: { string }

	if left.status == "Mapped" then
		local mappedRight: Types.MappedRouteSnapshot = right :: Types.MappedRouteSnapshot

		if left.version ~= mappedRight.version or left.sourceId ~= mappedRight.sourceId then
			return false
		end

		leftSources, rightSources = left.shadowedSources, mappedRight.shadowedSources
	else
		-- Diff visits a union of declared keys: both sides cannot be Unmapped.
		local gatedLeft: Types.GatedRouteSnapshot = left :: Types.GatedRouteSnapshot
		local gatedRight: Types.GatedRouteSnapshot = right :: Types.GatedRouteSnapshot
		leftSources, rightSources = gatedLeft.candidateSources, gatedRight.candidateSources
	end

	if #leftSources ~= #rightSources then
		return false
	end

	for position: number, id: string in leftSources do
		if rightSources[position] ~= id then
			return false
		end
	end

	return true
end

function Transitions.Diff(
	actor: ActorTypes.ActorView,
	before: Graph.Graph?,
	after: Graph.Graph?,
	oldInput: InputTypes.InputGraphSnapshot,
	newInput: InputTypes.InputGraphSnapshot,
	reason: string,
	invalidated: { [string]: boolean }?
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

		local force: boolean = false

		if invalidated ~= nil then
			if routeKey.kind == "Input" then
				force = invalidated[routeKey.inputId] == true
			elseif oldInput.recognition ~= nil then
				if routeKey.kind == "Sequence" then
					local machine: InputTypes.SequenceMachine? =
						oldInput.recognition.sequenceMachines[routeKey.sequenceId]

					for inputId: string in if machine ~= nil then machine.inputs else {} do
						if invalidated[inputId] then
							force = true
							break
						end
					end
				else
					local recognizer: InputTypes.RecognizerSnapshot? =
						oldInput.recognition.recognizers[routeKey.recognizerId]

					for _, inputId: string in if recognizer ~= nil then recognizer.definition.inputs else {} do
						if invalidated[inputId] then
							force = true
							break
						end
					end
				end
			end
		end

		if routeKey.kind ~= "Input" then
			local oldCatalog: InputTypes.RecognitionCatalog? = oldInput.recognition
			local newCatalog: InputTypes.RecognitionCatalog? = newInput.recognition
			local oldDefinition: unknown = nil
			local newDefinition: unknown = nil

			if routeKey.kind == "Sequence" then
				oldDefinition = if oldCatalog ~= nil then oldCatalog.sequenceMachines[routeKey.sequenceId] else nil
				newDefinition = if newCatalog ~= nil then newCatalog.sequenceMachines[routeKey.sequenceId] else nil
			else
				local oldRecognizer = if oldCatalog ~= nil then oldCatalog.recognizers[routeKey.recognizerId] else nil
				local newRecognizer = if newCatalog ~= nil then newCatalog.recognizers[routeKey.recognizerId] else nil
				oldDefinition = if oldRecognizer ~= nil then oldRecognizer.definition else nil
				newDefinition = if newRecognizer ~= nil then newRecognizer.definition else nil
			end

			force = force or not InputValue.Equal(oldDefinition, newDefinition)
		end

		if force or not snapshotsEqual(previous, nextSnapshot) then
			table.insert(
				changes,
				table.freeze({
					actor = actor,
					key = routeKey,
					previous = previous,
					next = nextSnapshot,
					reason = reason,
				})
			)
		end
	end

	return changes
end

return Transitions
