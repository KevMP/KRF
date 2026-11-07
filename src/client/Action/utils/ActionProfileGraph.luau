--!strict
local Types = require(script.Parent.Parent.types)
local ActorTypes = require(script.Parent.Parent.Parent.Actor.types)
local InputTypes = require(script.Parent.Parent.Parent.Input.types)
local InputValue = require(script.Parent.Parent.Parent.Input.utils.InputValue)
local Validator = require(script.Parent.Parent.ActionProfileValidator)
local Identity = require(script.Parent.ActionRouteIdentity)
local Limits = require(script.Parent.ActionRouteLimits)

export type Entry = {
	read sourceId: string,
	read priority: number,
	read version: number,
	read route: Validator.ValidatedRoute,
}

export type Graph = {
	read sources: { [string]: Validator.Profile },
	read index: { [string]: { Entry } },
	read keys: { string },
	read snapshots: { Types.ProfileSourceSnapshot },
}

export type Catalog = { [ActorTypes.ActorView]: Graph }

local Graph = {}
local unmapped: Types.RouteQuerySnapshot = table.freeze({ status = "Unmapped" :: "Unmapped" })

function Graph.Build(sources: { [string]: Validator.Profile }, previous: Graph?, version: number): (Graph?, string?)
	local index: { [string]: { Entry } } = {}
	local snapshots: { Types.ProfileSourceSnapshot } = {}

	for sourceId: string, profile: Validator.Profile in sources do
		table.insert(
			snapshots,
			table.freeze({ sourceId = sourceId, priority = profile.priority, routeCount = #profile.routes })
		)

		if #snapshots > Limits.MAX_SOURCES_PER_ACTOR then
			return nil, "ProfileSourceLimitExceeded"
		end

		for _, route: Validator.ValidatedRoute in profile.routes do
			local key: string = Identity.Canonical(route.when)
			local entries: { Entry } = index[key] or {}

			index[key] = entries

			for _, entry: Entry in entries do
				if entry.priority == profile.priority then
					return nil, "ProfilePriorityConflict"
				end
			end

			local routeVersion: number = version

			if previous ~= nil then
				for _, old: Entry in previous.index[key] or {} do
					if
						old.sourceId == sourceId
						and old.priority == profile.priority
						and InputValue.Equal(old.route, route)
					then
						routeVersion = old.version
						break
					end
				end
			end

			table.insert(
				entries,
				table.freeze({ sourceId = sourceId, priority = profile.priority, version = routeVersion, route = route })
			)
		end
	end

	local keys: { string } = {}

	for key: string, entries: { Entry } in index do
		table.insert(keys, key)

		table.sort(entries, function(left: Entry, right: Entry): boolean
			return left.priority > right.priority
		end)

		table.freeze(entries)
	end

	table.sort(keys)

	table.sort(snapshots, function(left: Types.ProfileSourceSnapshot, right: Types.ProfileSourceSnapshot): boolean
		return left.sourceId < right.sourceId
	end)

	return table.freeze({
		sources = table.freeze(sources),
		index = table.freeze(index),
		keys = table.freeze(keys),
		snapshots = table.freeze(snapshots),
	}),
		nil
end

-- Dispatch needs only the winning entry, without inspection snapshot allocations.
function Graph.Select(graph: Graph, key: string, input: InputTypes.InputGraphSnapshot): Entry?
	for _, entry: Entry in graph.index[key] or {} do
		local eligible: boolean = true

		for _, contextId: string in entry.route.requiredContexts do
			local context: InputTypes.ContextSnapshot? = input.contexts[contextId]

			if context == nil or not context.enabled then
				eligible = false
				break
			end
		end

		if eligible then
			return entry
		end
	end

	return nil
end

function Graph.Evaluate(graph: Graph?, key: string, input: InputTypes.InputGraphSnapshot): Types.RouteQuerySnapshot
	if graph == nil then
		return unmapped
	end

	local entries: { Entry }? = graph.index[key]

	if entries == nil then
		return unmapped
	end

	local winner: Entry? = Graph.Select(graph, key, input)
	local shadowed: { string } = {}

	for _, entry: Entry in entries do
		if entry ~= winner then
			table.insert(shadowed, entry.sourceId)
		end
	end

	if winner == nil then
		return table.freeze({ status = "Gated" :: "Gated", candidateSources = table.freeze(shadowed) })
	end

	local target: Types.RouteTarget = winner.route.target

	return table.freeze({
		status = "Mapped" :: "Mapped",
		sourceId = winner.sourceId,
		priority = winner.priority,
		targetKind = target.kind,
		actionId = if target.kind == "Fixed" then target.actionId else nil,
		dispatchMode = winner.route.dispatch.mode,
		dispatchPriority = winner.route.dispatch.priority,
		requiredContexts = winner.route.requiredContexts,
		shadowedSources = table.freeze(shadowed),
		version = winner.version,
	})
end

function Graph.Validate(catalog: Catalog, input: InputTypes.InputGraphSnapshot): boolean
	for _, graph: Graph in catalog do
		for _, profile: Validator.Profile in graph.sources do
			for _, route: Validator.ValidatedRoute in profile.routes do
				if Validator.Reference(route.when, route.requiredContexts, input) ~= nil then
					return false
				end
			end
		end
	end

	return true
end

return Graph
