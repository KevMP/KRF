--!strict
local Types = require(script.Parent.Parent.types)
local ActorTypes = require(script.Parent.Parent.Parent.Actor.types)
local InputTypes = require(script.Parent.Parent.Parent.Input.types)
local Observers = require(script.Parent.Parent.Parent.Parent.shared.Signal.PrivateObservers)
local Graph = require(script.Parent.ActionProfileGraph)
local Identity = require(script.Parent.ActionRouteIdentity)
local Limits = require(script.Parent.ActionRouteLimits)

export type Access = {
	IsCurrent: (ActorTypes.ActorView, number, number) -> boolean,
	Selections: Observers.Registry<(Types.ActionRouteSelection) -> ()>,
	Sink: (Types.ActionRouteSelection, any?) -> (),
	Report: (string) -> (),
}

type Mapped = { canonical: string, entry: Graph.Entry, candidate: InputTypes.RecognitionCandidate }

local Dispatch = {}

local function sharesRoot(
	candidate: InputTypes.RecognitionCandidate,
	envelope: InputTypes.InputCandidateEnvelope
): boolean
	return candidate.kind ~= "Input"
		and envelope.kind == "Root"
		and candidate.immediate
		and candidate.rootInputOrdinal == envelope.rootInputOrdinal
end

local function compare(left: Mapped, right: Mapped): number
	local leftPriority: number = left.entry.route.dispatch.priority
	local rightPriority: number = right.entry.route.dispatch.priority

	if leftPriority ~= rightPriority then
		return if leftPriority > rightPriority then 1 else -1
	end

	local leftSequence: boolean = left.candidate.kind == "Sequence"
	local rightSequence: boolean = right.candidate.kind == "Sequence"

	if leftSequence ~= rightSequence then
		return if leftSequence then 1 else -1
	end

	if
		left.candidate.kind == "Sequence"
		and right.candidate.kind == "Sequence"
		and left.candidate.matchedStepCount ~= right.candidate.matchedStepCount
	then
		return if left.candidate.matchedStepCount > right.candidate.matchedStepCount then 1 else -1
	end

	return 0
end

local function selectRoutes(
	graph: Graph.Graph,
	envelope: InputTypes.InputCandidateEnvelope,
	inputGraph: InputTypes.InputGraphSnapshot,
	report: (string) -> ()
): { Mapped }
	local independent: { Mapped } = {}
	local exclusive: Mapped? = nil
	local input: Mapped? = nil
	local ambiguous: boolean = false
	local tiedRoot: boolean = false
	local seen: { [string]: boolean } = {}

	for _, candidate: InputTypes.RecognitionCandidate in envelope.candidates do
		if candidate.kind == "Input" and not candidate.routeEligible then
			continue
		end

		local canonical: string = Identity.Canonical(candidate)

		if seen[canonical] then
			continue
		end

		seen[canonical] = true

		local entry: Graph.Entry? = Graph.Select(graph, canonical, inputGraph)

		if entry == nil then
			continue
		end

		local mapped: Mapped = { canonical = canonical, entry = entry, candidate = candidate }

		if candidate.kind == "Input" then
			if
				input == nil
				or (
					candidate.gesture == "DoubleTapped"
					and input.candidate.kind == "Input"
					and input.candidate.gesture == "Pressed"
				)
			then
				input = mapped
			end
		elseif entry.route.dispatch.mode == "Independent" then
			table.insert(independent, mapped)
		else
			local rank: number = if exclusive == nil then 1 else compare(mapped, exclusive)

			if rank > 0 then
				exclusive = mapped
				ambiguous = false
				tiedRoot = sharesRoot(candidate, envelope)
			elseif rank == 0 then
				ambiguous = true
				tiedRoot = tiedRoot or sharesRoot(candidate, envelope)
			end
		end
	end

	local masked: boolean = false

	if exclusive ~= nil then
		masked = if ambiguous then tiedRoot else sharesRoot(exclusive.candidate, envelope)

		if ambiguous then
			report("AmbiguousExclusiveRoutes")
		else
			table.insert(independent, exclusive)
		end
	end

	if input ~= nil and not masked then
		table.insert(independent, input)
	end

	if #independent > Limits.MAX_INTENTS_PER_OCCURRENCE then
		report("RouteFanoutExceeded")

		return {}
	end

	-- Order independent handoffs deterministically without using ID order to
	-- choose a winner in a tied exclusive collision.
	table.sort(independent, function(left: Mapped, right: Mapped): boolean
		return left.canonical < right.canonical
	end)

	return independent
end

local function holdOwner(
	candidate: InputTypes.RecognitionCandidate,
	envelope: InputTypes.InputCandidateEnvelope,
	input: InputTypes.InputOwner
): InputTypes.RecognitionHoldOwner?
	local owner: InputTypes.RecognitionHoldOwner? = nil

	if candidate.kind == "Input" then
		if candidate.gesture ~= "Tap" and candidate.pressEpochId ~= nil and candidate.pressEpochGeneration ~= nil then
			owner = {
				inputId = candidate.inputId,
				inputGeneration = candidate.pressEpochGeneration,
				pressEpochId = candidate.pressEpochId,
				isActiveAfterCommit = true,
			}
		end
	elseif sharesRoot(candidate, envelope) and envelope.kind == "Root" and envelope.isRootEpochActiveAfterCommit then
		local proposed: InputTypes.RecognitionHoldOwner? = candidate.holdOwner

		if
			proposed ~= nil
			and proposed.inputId == envelope.rootInputId
			and proposed.inputGeneration == envelope.rootInputEpochGeneration
			and proposed.pressEpochId == envelope.rootInputEpochId
		then
			owner = proposed
		end
	end

	if owner == nil or not input.IsPressEpochActive(owner.inputId, owner.pressEpochId, owner.inputGeneration) then
		return nil
	end

	return table.freeze({
		inputId = owner.inputId,
		inputGeneration = owner.inputGeneration,
		pressEpochId = owner.pressEpochId,
		isActiveAfterCommit = true,
	})
end

local function resolve(
	mapped: Mapped,
	actor: ActorTypes.ActorView,
	envelope: InputTypes.InputCandidateEnvelope,
	report: (string) -> ()
): Types.ResolvedAction?
	local target: Types.RouteTarget = mapped.entry.route.target

	if target.kind == "Fixed" then
		return { actionId = target.actionId }
	end

	local context: Types.RouteResolveContext = table.freeze({
		actor = actor,
		actorId = actor:GetId(),
		sourceId = mapped.entry.sourceId,
		key = mapped.entry.route.when,
		timestamp = envelope.timestamp,
		envelope = envelope,
		candidate = mapped.candidate,
	})

	local success: boolean, failure: string?, result: any = Observers.Run(target.resolve, context)

	if not success then
		report(if failure == "Yielded" then "RouteResolverYielded" else "RouteResolverFailed")

		return nil
	end

	if result == nil then
		report("ResolvedNoAction")

		return nil
	end

	if not Identity.Plain(result, { actionId = true, parameters = true }) then
		report("InvalidResolvedAction")

		return nil
	end

	if not Identity.IsId(result.actionId) then
		report("InvalidActionId")

		return nil
	end

	return { actionId = result.actionId, parameters = result.parameters }
end

function Dispatch.new(
	input: InputTypes.InputOwner,
	access: Access
): (ActorTypes.ActorView, number, Graph.Graph, InputTypes.InputCandidateEnvelope) -> ()
	local lastGeneration: number = -1
	local lastOrdinal: number = -1

	return function(
		actor: ActorTypes.ActorView,
		generation: number,
		graph: Graph.Graph,
		envelope: InputTypes.InputCandidateEnvelope
	): ()
		local inputGraph: InputTypes.InputGraphSnapshot = input.GetGraphSnapshot()

		if
			envelope.inputGeneration ~= inputGraph.generation
			or not access.IsCurrent(actor, generation, inputGraph.generation)
		then
			return
		end

		if lastGeneration == generation and envelope.occurrenceOrdinal <= lastOrdinal then
			return
		end

		lastGeneration, lastOrdinal = generation, envelope.occurrenceOrdinal
		local mapped: { Mapped } = selectRoutes(graph, envelope, inputGraph, access.Report)

		for _, route: Mapped in mapped do
			if not access.IsCurrent(actor, generation, inputGraph.generation) then
				break
			end

			local resolved: Types.ResolvedAction? = resolve(route, actor, envelope, access.Report)

			if resolved == nil then
				continue
			end

			if not access.IsCurrent(actor, generation, inputGraph.generation) then
				break
			end

			local selection: Types.ActionRouteSelection = table.freeze({
				actor = actor,
				actorId = actor:GetId(),
				sourceId = route.entry.sourceId,
				routeVersion = route.entry.version,
				selectionGeneration = generation,
				key = route.entry.route.when,
				actionId = resolved.actionId,
				envelope = envelope,
				candidate = route.candidate,
				holdOwner = holdOwner(route.candidate, envelope, input),
			})

			-- An observer may retire this Actor: later observers and the sink stop there.
			for _, entry in access.Selections.Snapshot() do
				if not access.IsCurrent(actor, generation, inputGraph.generation) then
					break
				end

				if entry.active and not Observers.Run(entry.callback, selection) then
					access.Report("ActionSelectionObserverFailed")
				end
			end

			if not access.IsCurrent(actor, generation, inputGraph.generation) then
				break
			end

			local handedOff: boolean = Observers.Run(access.Sink, selection, resolved.parameters)

			if not handedOff then
				access.Report("ActionRouteSinkFailed")
			end
		end
	end
end

return Dispatch
