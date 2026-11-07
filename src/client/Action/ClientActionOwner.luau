--!strict
local Types = require(script.Parent.types)
local ActorTypes = require(script.Parent.Parent.Actor.types)
local InputTypes = require(script.Parent.Parent.Input.types)
local Registry = require(script.Parent.Parent.Actor.utils.ActorViewRegistryState)
local Observers = require(script.Parent.Parent.Parent.shared.Signal.PrivateObservers)
local Validator = require(script.Parent.ActionProfileValidator)
local Identity = require(script.Parent.utils.ActionRouteIdentity)
local Graph = require(script.Parent.utils.ActionProfileGraph)
local Transitions = require(script.Parent.utils.ActionRouteTransitions)
local Dispatch = require(script.Parent.utils.ActionRouteDispatch)
local Switching = require(script.Parent.utils.ActionActorSwitch)
local Plans = require(script.Parent.utils.ActionPreparedPlans)
local Updates = require(script.Parent.utils.ActionProfileUpdates)
local Retirement = require(script.Parent.utils.ActionActivationRetirement)

local Owner = {}

-- Only this owner publishes the catalog, selected identity and generation.
-- Collaborators compile immutable values or own bounded prepared capabilities.
function Owner.new(options: Types.ClientActionOwnerOptions): Types.ClientActionOwner
	local input: InputTypes.InputOwner = options.Input
	local catalog: Graph.Catalog = {}
	local controlled: ActorTypes.ActorView? = nil
	local generation: number = 1
	local busy: number = 0
	local destroyed: boolean = false
	local switching: boolean = false
	local publishedInputGeneration: number? = nil
	local disconnects: { () -> () } = {}

	local selections: Observers.Registry<(Types.ActionRouteSelection) -> ()> = Observers.new(
		64,
		"ActionSelectionObserverLimitExceeded"
	) :: Observers.Registry<
		(Types.ActionRouteSelection) -> ()
	>

	local routes: Observers.Registry<(Types.EffectiveRouteTransition) -> ()> = Observers.new(
		64,
		"ActionRouteObserverLimitExceeded"
	) :: Observers.Registry<
		(Types.EffectiveRouteTransition) -> ()
	>

	local profiles: Plans.Store<Graph.Catalog> = Plans.new(function() end)
	local switches: Switching.Owner

	local function report(reason: string): ()
		pcall(options.ReportFault, reason)
	end

	local function available(actor: ActorTypes.ActorView): boolean
		return Registry.IsCurrent(actor) and not Registry.IsInvalidating(actor) and actor:IsAvailable()
	end

	local function unavailable(): string?
		if destroyed then
			return "ClientNotReady"
		end

		if busy > 0 or Registry.IsInvalidationInProgress() then
			return "DispatchInProgress"
		end

		local status: string? = input.GetMutationStatus()

		if status == "InputMutationReentrant" or status == "InputMutationDuringValidation" then
			return "DispatchInProgress"
		end

		if not options.IsReady() then
			return "ClientNotReady"
		end

		return status
	end

	local function advance(): ()
		generation += 1
		profiles.Clear()
		switches.Clear()
	end

	local function notify(changes: { Types.EffectiveRouteTransition }): ()
		for _, change: Types.EffectiveRouteTransition in changes do
			for _, entry in routes.Snapshot() do
				if entry.active then
					local success: boolean = Observers.Run(entry.callback, change)

					if not success then
						report("ActionRouteObserverFailed")
					end
				end
			end
		end
	end

	local function destroy(): ()
		if destroyed then
			return
		end

		destroyed = true
		publishedInputGeneration = nil
		controlled = nil
		catalog = {}
		advance()

		for _, disconnect in disconnects do
			disconnect()
		end

		table.clear(disconnects)
		selections.Destroy()
		routes.Destroy()

		if options.OnDestroyed ~= nil then
			Observers.Run(options.OnDestroyed)
		end
	end

	local function validateActor(actor: ActorTypes.ActorView?): string?
		local reason: string? = unavailable()

		if reason ~= nil then
			return reason
		end

		return if actor ~= nil and not available(actor) then "ActorViewUnavailable" else nil
	end

	local function mutate(
		actor: ActorTypes.ActorView,
		sourceId: string,
		value: Types.ControlProfile?
	): (boolean, string?)
		local reason: string? = validateActor(actor)

		if reason ~= nil then
			return false, reason
		end

		local graph: InputTypes.InputGraphSnapshot = input.GetGraphSnapshot()
		local nextCatalog: Graph.Catalog?

		nextCatalog, reason = Updates.Prepare(
			catalog,
			{ { actor = actor, sourceId = sourceId, profile = value } },
			graph,
			generation + 1,
			validateActor
		)

		if nextCatalog == nil then
			return false, reason
		end

		local previousSource: Validator.Profile? = if catalog[actor] ~= nil
			then catalog[actor].sources[sourceId]
			else nil

		local nextSource: Validator.Profile? = if nextCatalog[actor] ~= nil
			then nextCatalog[actor].sources[sourceId]
			else nil

		local same: boolean = Updates.EqualSource(previousSource, nextSource)

		local changes: { Types.EffectiveRouteTransition } =
			Transitions.Diff(actor, catalog[actor], nextCatalog[actor], graph, graph, "ProfileChanged")

		if same then
			return true, nil
		end

		busy += 1
		catalog = nextCatalog
		advance()
		notify(changes)
		busy -= 1

		return true, nil
	end

	switches = Switching.new(input, options.ActivationGuard, {
		Current = function(): ActorTypes.ActorView?
			return controlled
		end,
		Validate = validateActor,
		CanPublish = function(actor: ActorTypes.ActorView?): boolean
			return not destroyed and options.IsReady() and (actor == nil or available(actor))
		end,
		Fence = function(enter: boolean): ()
			busy += if enter then 1 else -1
			switching = enter
		end,
		Publish = function(actor: ActorTypes.ActorView?): ()
			local old: ActorTypes.ActorView? = controlled
			controlled = actor
			advance()
			local graph: InputTypes.InputGraphSnapshot = input.GetGraphSnapshot()

			if old ~= nil then
				notify(Transitions.Diff(old, catalog[old], nil, graph, graph, "ActorChanged"))
			end

			if actor ~= nil then
				notify(Transitions.Diff(actor, nil, catalog[actor], graph, graph, "ActorChanged"))
			end
		end,
		Fail = function(): ()
			destroy()
			input.Disarm("ActorSwitchFailed")
		end,
		Report = report,
	})

	local dispatch = Dispatch.new(input, {
		IsCurrent = function(actor: ActorTypes.ActorView, selectedGeneration: number, inputGeneration: number): boolean
			return not destroyed
				and options.IsReady()
				and generation == selectedGeneration
				and controlled == actor
				and available(actor)
				and input.GetGraphSnapshot().generation == inputGeneration
				and input.GetMutationStatus() ~= "ClientNotReady"
		end,
		Notify = function(selection: Types.ActionRouteSelection): ()
			for _, entry in selections.Snapshot() do
				if entry.active then
					local success: boolean = Observers.Run(entry.callback, selection)

					if not success then
						report("ActionSelectionObserverFailed")
					end
				end
			end
		end,
		Sink = options.Sink,
		Report = report,
	})

	local installed: boolean, failure: any = pcall(function(): ()
		table.insert(
			disconnects,
			input.RegisterGraphValidator(
				function(graph: InputTypes.InputGraphSnapshot, proposed: any?): (boolean, string?)
					local desired: Graph.Catalog = catalog

					if proposed ~= nil then
						local prepared: Graph.Catalog? = profiles.Read(proposed)

						if prepared == nil then
							return false, "InvalidProfileGraph"
						end

						desired = prepared
					end

					local valid: boolean = Graph.Validate(desired, graph)

					return valid, if valid then nil else "ProfileDependencyMissing"
				end
			)
		)

		table.insert(
			disconnects,
			input.ObserveConfigurationCommit(function(change: InputTypes.InputGraphChange): ()
				if destroyed or switching then
					return
				end

				if input.GetMutationStatus() == "InputRuntimeFaulted" or not Graph.Validate(catalog, change.next) then
					local retirementReason: string = if table.find(change.reasons, "InputRuntimeFaulted") ~= nil
						then "InputRuntimeFaulted"
						else "ProfilePublicationMissing"

					busy += 1
					local previous: Graph.Catalog = catalog
					catalog = {}
					controlled = nil
					advance()

					for actor: ActorTypes.ActorView, graph: Graph.Graph in previous do
						notify(Transitions.Diff(actor, graph, nil, change.previous, change.next, "InputInvalidated"))
					end

					busy -= 1
					destroy()
					report(retirementReason)

					return
				end

				local alreadyPublished: boolean = publishedInputGeneration == change.next.generation
				publishedInputGeneration = nil

				if alreadyPublished then
					return
				end

				busy += 1
				local invalidated: { [string]: boolean } = {}

				for _, id: string in change.affectedInputIds do
					invalidated[id] = true
				end

				local changes: { Types.EffectiveRouteTransition } = {}

				for actor: ActorTypes.ActorView, graph: Graph.Graph in catalog do
					for _, transition: Types.EffectiveRouteTransition in
						Transitions.Diff(
							actor,
							graph,
							graph,
							change.previous,
							change.next,
							if #change.reasons > 0 then table.concat(change.reasons, ",") else "RecognitionChanged",
							invalidated
						)
					do
						table.insert(changes, transition)
					end
				end

				profiles.Clear()
				switches.Clear()
				notify(changes)
				busy -= 1
			end)
		)

		table.insert(
			disconnects,
			input.ObserveCandidateEnvelope(function(envelope: InputTypes.InputCandidateEnvelope): ()
				local actor: ActorTypes.ActorView? = controlled

				if destroyed or busy > 0 or actor == nil or catalog[actor] == nil then
					return
				end

				busy += 1
				local success: boolean = Observers.Run(dispatch, actor, generation, catalog[actor], envelope)

				if not success then
					report("ActionRouteDispatchFailed")
				end

				busy -= 1
			end, function(): boolean
				return not destroyed and controlled ~= nil and catalog[controlled] ~= nil
			end)
		)

		table.insert(
			disconnects,
			Registry.ObserveInvalidation(function(actor: ActorTypes.ActorView, reason: string): ()
				if destroyed then
					return
				end

				busy += 1

				local retirement: Types.ActorSwitchRetirement? = nil

				-- The switch owns this original retirement through its post-commit
				-- handoff. Identity/catalog retirement still happens in this barrier.
				if not switches.IsRetiring(actor) then
					local preparedRetirement: Types.ActorSwitchRetirement?, retirementReason: string? =
						Retirement.Prepare(
							options.ActivationGuard,
							actor,
							if controlled == actor then nil else controlled
						)

					retirement = preparedRetirement

					if retirementReason ~= nil then
						report(retirementReason)
					end
				end

				local previous: Graph.Graph? = catalog[actor]

				catalog[actor] = nil

				if controlled == actor then
					controlled = nil
				end

				if retirement ~= nil and not Observers.Run(retirement.Commit) then
					report("ActorRetirementCommitFailed")
					retirement = nil
				end

				advance()
				local graph: InputTypes.InputGraphSnapshot = input.GetGraphSnapshot()
				notify(Transitions.Diff(actor, previous, nil, graph, graph, reason))

				if retirement ~= nil and not Observers.Run(retirement.AfterCommit) then
					report("ActorRetirementAfterCommitFailed")
				end

				busy -= 1
			end)
		)
	end)

	if not installed then
		destroy()
		error(failure, 0)
	end

	return {
		SetProfileSource = function(
			actor: ActorTypes.ActorView,
			sourceId: string,
			profile: Types.ControlProfile
		): (boolean, string?)
			if profile == nil then
				return false, validateActor(actor) or "InvalidControlProfile"
			end

			return mutate(actor, sourceId, profile)
		end,
		RemoveProfileSource = function(actor: ActorTypes.ActorView, sourceId: string): (boolean, string?)
			return mutate(actor, sourceId, nil)
		end,
		GetControlledActor = function(): ActorTypes.ActorView?
			return if destroyed
					or not options.IsReady()
					or (controlled ~= nil and not available(controlled))
				then nil
				else controlled
		end,
		SetControlledActor = function(actor: ActorTypes.ActorView?): (boolean, string?)
			local plan: Types.PreparedActorSwitch?, reason: string? = switches.Prepare(actor)

			if plan == nil then
				return false, reason
			end

			return switches.Commit(plan)
		end,
		PrepareControlledActor = switches.Prepare,
		CommitControlledActor = switches.Commit,
		CommitPreparedProfiles = function(plan: Types.PreparedProfileGraph): (boolean, string?)
			if destroyed or not options.IsReady() then
				return false, "ClientNotReady"
			end

			if busy > 0 then
				return false, "DispatchInProgress"
			end

			if not input.IsCommitFenced() then
				return false, "InputCommitFenceRequired"
			end

			local desired: Graph.Catalog? = profiles.Read(plan)

			if desired == nil then
				return false, "InvalidProfileGraph"
			end

			local graph: InputTypes.InputGraphSnapshot = input.GetGraphSnapshot()

			local commit: InputTypes.InputCommitContext =
				assert(input.GetCommitContext(), "Expected input commit fence")

			if not Graph.Validate(desired, graph) then
				return false, "ProfileDependencyMissing"
			end

			local changes: { Types.EffectiveRouteTransition } = {}
			local actors: { [ActorTypes.ActorView]: boolean } = {}
			local invalidated: { [string]: boolean } = {}

			for inputId: string in commit.invalidatedInputIds do
				invalidated[inputId] = true
			end

			for actor: ActorTypes.ActorView in catalog do
				actors[actor] = true
			end

			for actor: ActorTypes.ActorView in desired do
				actors[actor] = true
			end

			for actor: ActorTypes.ActorView in actors do
				for _, change: Types.EffectiveRouteTransition in
					Transitions.Diff(
						actor,
						catalog[actor],
						desired[actor],
						commit.previous,
						graph,
						"ProfileChanged",
						invalidated
					)
				do
					table.insert(changes, change)
				end
			end

			busy += 1
			catalog = desired
			publishedInputGeneration = graph.generation
			advance()
			notify(changes)
			busy -= 1

			return true, nil
		end,
		GetEffectiveRoute = function(actor: ActorTypes.ActorView, key: Types.RouteKey): Types.RouteQuerySnapshot?
			if destroyed or not options.IsReady() or not available(actor) then
				return nil
			end

			local normalized: Types.RouteKey? = Identity.Key(key)

			if normalized == nil then
				return nil
			end

			local snapshot: Types.RouteQuerySnapshot =
				Graph.Evaluate(catalog[actor], Identity.Canonical(normalized), input.GetGraphSnapshot())

			return snapshot
		end,
		GetProfileSources = function(actor: ActorTypes.ActorView): { Types.ProfileSourceSnapshot }
			if destroyed or not options.IsReady() or not available(actor) or catalog[actor] == nil then
				return table.freeze({} :: { Types.ProfileSourceSnapshot })
			end

			return catalog[actor].snapshots
		end,
		ObserveSelection = selections.Add,
		ObserveRoutes = routes.Add,
		PrepareProfiles = function(
			updates: { Types.ProfileUpdate },
			desiredInput: InputTypes.InputGraphSnapshot?
		): (Types.PreparedProfileGraph?, string?)
			local reason: string? = unavailable()

			if reason ~= nil then
				return nil, reason
			end

			local graph: InputTypes.InputGraphSnapshot = desiredInput or input.GetGraphSnapshot()
			local desired: Graph.Catalog?
			desired, reason = Updates.Prepare(catalog, updates, graph, generation + 1, validateActor)

			if desired == nil then
				return nil, reason
			end

			return profiles.Create(desired)
		end,
		Destroy = destroy,
	}
end

return Owner
