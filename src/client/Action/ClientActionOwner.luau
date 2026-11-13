--!strict
local Types = require(script.Parent.types)
local ActorTypes = require(script.Parent.Parent.Actor.types)
local InputTypes = require(script.Parent.Parent.Input.types)
local Registry = require(script.Parent.Parent.Actor.utils.ActorViewRegistryState)
local Observers = require(script.Parent.Parent.Parent.shared.Signal.PrivateObservers)
local Identity = require(script.Parent.utils.ActionRouteIdentity)
local Graph = require(script.Parent.utils.ActionProfileGraph)
local Transitions = require(script.Parent.utils.ActionRouteTransitions)
local Dispatch = require(script.Parent.utils.ActionRouteDispatch)
local Switching = require(script.Parent.utils.ActionActorSwitch)
local Publication = require(script.Parent.utils.ActionProfilePublication)
local ActorRetirement = require(script.Parent.utils.ActionActorRetirement)
local Validity = require(script.Parent.utils.ActionInputValidity)

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
	local validity: Validity.Owner? = nil
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

	local profiles: Publication.Owner
	local switches: Switching.Owner

	local function report(reason: string): ()
		pcall(options.ReportFault, reason)
	end

	local function available(actor: ActorTypes.ActorView): boolean
		return Registry.IsCurrent(actor) and not Registry.IsInvalidating(actor) and actor:IsAvailable()
	end

	local function unavailable(internal: boolean?): string?
		if destroyed then
			return "ClientNotReady"
		end

		if busy > 0 or Registry.IsInvalidationInProgress() then
			return "DispatchInProgress"
		end

		local status: string? = input.GetMutationStatus(internal)

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

	local notify: ({ Types.EffectiveRouteTransition }) -> () = Transitions.Publisher(routes, report)

	local function destroy(): ()
		if destroyed then
			return
		end

		destroyed = true
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

	local function validateActor(actor: ActorTypes.ActorView?, internal: boolean?): string?
		local reason: string? = unavailable(internal)

		if reason ~= nil then
			return reason
		end

		return if actor ~= nil and not available(actor) then "ActorViewUnavailable" else nil
	end

	local function validatePreparedActor(actor: ActorTypes.ActorView?): string?
		return validateActor(actor, true)
	end

	profiles = Publication.new(input, {
		Current = function(): Graph.Catalog
			return catalog
		end,
		Selected = function(): ActorTypes.ActorView?
			return controlled
		end,
		Version = function(): number
			return generation
		end,
		ValidateActor = validatePreparedActor,
		Available = available,
		Install = function(desired: Graph.Catalog, selection: Types.ActorPublication?): ()
			catalog = desired

			if selection ~= nil then
				controlled = selection.actor
			end

			advance()
		end,
		Notify = function(changes: { Types.EffectiveRouteTransition }): ()
			busy += 1
			notify(changes)
			busy -= 1
		end,
	})

	local function mutate(
		actor: ActorTypes.ActorView,
		sourceId: string,
		value: Types.ControlProfile?
	): (boolean, string?)
		local reason: string? = validateActor(actor)

		if reason ~= nil then
			return false, reason
		end

		return profiles.Replace(actor, sourceId, value)
	end

	switches = Switching.new(input, options.ActivationGuard, {
		Current = function(): ActorTypes.ActorView?
			return controlled
		end,
		Validate = validatePreparedActor,
		CanPublish = function(actor: ActorTypes.ActorView?): boolean
			return not destroyed and options.IsReady() and (actor == nil or available(actor))
		end,
		Fence = function(enter: boolean): ()
			busy += if enter then 1 else -1
			switching = enter
		end,
		Publish = function(actor: ActorTypes.ActorView?, plan: Types.PreparedProfileGraph?): ()
			if plan ~= nil then
				local committed: boolean, reason: string? = profiles.Commit(plan, { actor = actor })
				assert(committed, reason)

				assert(validity, "Expected installed input validity observer").MarkPublished(
					input.GetGraphSnapshot().generation
				)
			else
				profiles.Select(actor)
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
		Selections = selections,
		Sink = options.Sink,
		Report = report,
	})

	local installed: boolean, failure: unknown = pcall(function(): ()
		validity = Validity.new(input, {
			Catalog = function(): Graph.Catalog
				return catalog
			end,
			Prepared = profiles.Read,
			IsDestroyed = function(): boolean
				return destroyed
			end,
			IsSwitching = function(): boolean
				return switching
			end,
			Publish = function(changes: { Types.EffectiveRouteTransition }): ()
				busy += 1
				profiles.Clear()
				switches.Clear()
				notify(changes)
				busy -= 1
			end,
			Fail = function(changes: { Types.EffectiveRouteTransition }, reason: string): ()
				busy += 1
				catalog = {}
				controlled = nil
				advance()
				notify(changes)
				busy -= 1
				destroy()
				report(reason)
			end,
		})

		table.insert(disconnects, validity.Destroy)

		table.insert(
			disconnects,
			input.ObserveCandidateEnvelope(function(envelope: InputTypes.InputCandidateEnvelope): ()
				local actor: ActorTypes.ActorView? = controlled

				if
					destroyed
					or busy > 0
					or input.IsControlDispatchBlocked()
					or actor == nil
					or catalog[actor] == nil
				then
					return
				end

				busy += 1
				local success: boolean = Observers.Run(dispatch, actor, generation, catalog[actor], envelope)

				if not success then
					report("ActionRouteDispatchFailed")
				end

				busy -= 1
			end, true)
		)

		table.insert(
			disconnects,
			Registry.ObserveInvalidation(ActorRetirement.new(input, options.ActivationGuard, {
				Current = function(): ActorTypes.ActorView?
					return controlled
				end,
				IsDestroyed = function(): boolean
					return destroyed
				end,
				IsRetiring = switches.IsRetiring,
				Busy = function(enter: boolean): ()
					busy += if enter then 1 else -1
				end,
				Remove = function(actor: ActorTypes.ActorView): Graph.Graph?
					local previous: Graph.Graph? = catalog[actor]

					catalog[actor] = nil

					if controlled == actor then
						controlled = nil
					end

					advance()

					return previous
				end,
				Notify = notify,
				Report = report,
			}))
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
			Observers.CheckReentry()

			if profile == nil then
				return false, validateActor(actor) or "InvalidControlProfile"
			end

			return mutate(actor, sourceId, profile)
		end,
		RemoveProfileSource = function(actor: ActorTypes.ActorView, sourceId: string): (boolean, string?)
			Observers.CheckReentry()

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
			Observers.CheckReentry()
			local rejection: string? = unavailable()

			if rejection ~= nil then
				return false, rejection
			end

			local plan: Types.PreparedActorSwitch?, reason: string? = switches.Prepare(actor)

			if plan == nil then
				return false, reason
			end

			return switches.Commit(plan)
		end,
		PrepareControlledActor = switches.Prepare,
		CommitControlledActor = function(plan: Types.PreparedActorSwitch): (boolean, string?)
			return switches.Commit(plan)
		end,
		CommitControlledActorWithInput = switches.Commit,
		ReleasePreparedProfiles = profiles.Release,
		ReleaseControlledActor = switches.Release,
		CommitPreparedProfiles = function(plan: Types.PreparedProfileGraph): (boolean, string?)
			if destroyed or not options.IsReady() then
				return false, "ClientNotReady"
			end

			if busy > 0 then
				return false, "DispatchInProgress"
			end

			busy += 1
			local accepted: boolean, reason: string? = profiles.Commit(plan)
			busy -= 1

			if accepted then
				assert(validity, "Expected installed input validity observer").MarkPublished(
					input.GetGraphSnapshot().generation
				)
			end

			return accepted, reason
		end,
		GetEffectiveRoute = function(actor: ActorTypes.ActorView, key: Types.RouteKey): Types.RouteQuerySnapshot?
			if destroyed or not options.IsReady() or not available(actor) then
				return nil
			end

			local normalized: Types.RouteKey? = Identity.Key(key)

			if normalized == nil then
				return nil
			end

			return Graph.Evaluate(catalog[actor], Identity.Canonical(normalized), input.GetGraphSnapshot())
		end,
		GetProfileSources = function(actor: ActorTypes.ActorView): { Types.ProfileSourceSnapshot }
			if destroyed or not options.IsReady() or not available(actor) or catalog[actor] == nil then
				return table.freeze({} :: { Types.ProfileSourceSnapshot })
			end

			return catalog[actor].snapshots
		end,
		ObserveSelection = selections.Add,
		ObserveRoutes = routes.Add,
		PrepareProfiles = profiles.Prepare,
		Destroy = destroy,
	}
end

return Owner
