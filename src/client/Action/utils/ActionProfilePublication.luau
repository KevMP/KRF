--!strict
local Types = require(script.Parent.Parent.types)
local ActorTypes = require(script.Parent.Parent.Parent.Actor.types)
local InputTypes = require(script.Parent.Parent.Parent.Input.types)
local Value = require(script.Parent.Parent.Parent.Input.utils.InputValue)
local Graph = require(script.Parent.ActionProfileGraph)
local Validator = require(script.Parent.Parent.ActionProfileValidator)
local Updates = require(script.Parent.ActionProfileUpdates)
local Transitions = require(script.Parent.ActionRouteTransitions)
local Plans = require(script.Parent.ActionPreparedPlans)

export type Access = {
	Current: () -> Graph.Catalog,
	Selected: () -> ActorTypes.ActorView?,
	Version: () -> number,
	ValidateActor: (ActorTypes.ActorView?) -> string?,
	Available: (ActorTypes.ActorView) -> boolean,
	Install: (Graph.Catalog, Types.ActorPublication?) -> (),
	Notify: ({ Types.EffectiveRouteTransition }) -> (),
}

export type Owner = {
	Replace: (ActorTypes.ActorView, string, Types.ControlProfile?) -> (boolean, string?),
	Prepare: ({ Types.ProfileUpdate }, InputTypes.InputGraphSnapshot?) -> (Types.PreparedProfileGraph?, string?),
	Read: (unknown) -> Graph.Catalog?,
	Release: (Types.PreparedProfileGraph) -> (),
	Commit: (Types.PreparedProfileGraph, Types.ActorPublication?) -> (boolean, string?),
	Select: (ActorTypes.ActorView?) -> (),
	Clear: () -> (),
}

local Publication = {}

-- Prepared profile ownership and route-diff planning have one lifecycle. Only
-- Install crosses back into the owner, before any route observation is delivered.
function Publication.new(input: InputTypes.InputOwner, access: Access): Owner
	local plans: Plans.Store<Graph.Catalog> = Plans.new(function() end)

	local function publish(desired: Graph.Catalog, selection: Types.ActorPublication?): ()
		local previous: Graph.Catalog = access.Current()
		local graph: InputTypes.InputGraphSnapshot = input.GetGraphSnapshot()
		local commit: InputTypes.InputCommitContext = assert(input.GetCommitContext(), "InputCommitFenceRequired")
		local before: InputTypes.InputGraphSnapshot = commit.previous

		local changes: { Types.EffectiveRouteTransition } =
			Transitions.DiffCatalogs(previous, desired, before, graph, "ProfileChanged", commit.invalidatedInputIds)

		local oldActor: ActorTypes.ActorView? = access.Selected()
		local switched: boolean = selection ~= nil and selection.actor ~= oldActor

		if selection ~= nil and selection.actor ~= oldActor then
			if oldActor ~= nil then
				for _, change in Transitions.Diff(oldActor, previous[oldActor], nil, graph, graph, "ActorChanged") do
					table.insert(changes, change)
				end
			end

			local newActor: ActorTypes.ActorView? = selection.actor

			if newActor ~= nil then
				for _, change in Transitions.Diff(newActor, nil, desired[newActor], graph, graph, "ActorChanged") do
					table.insert(changes, change)
				end
			end
		end

		if switched or not Value.Equal(previous, desired) then
			access.Install(desired, selection)
		end

		access.Notify(changes)
	end

	return {
		Replace = function(
			actor: ActorTypes.ActorView,
			sourceId: string,
			value: Types.ControlProfile?
		): (boolean, string?)
			local current: Graph.Catalog = access.Current()
			local graph: InputTypes.InputGraphSnapshot = input.GetGraphSnapshot()

			local desired: Graph.Catalog?, reason: string? = Updates.Prepare(
				current,
				{ { actor = actor, sourceId = sourceId, profile = value } },
				graph,
				access.Version() + 1,
				access.ValidateActor
			)

			if desired == nil then
				return false, reason
			end

			local previousSource: Validator.Profile? = if current[actor] ~= nil
				then current[actor].sources[sourceId]
				else nil

			local nextSource: Validator.Profile? = if desired[actor] ~= nil
				then desired[actor].sources[sourceId]
				else nil

			if Value.Equal(previousSource, nextSource) then
				return true, nil
			end

			local changes: { Types.EffectiveRouteTransition } =
				Transitions.Diff(actor, current[actor], desired[actor], graph, graph, "ProfileChanged")

			access.Install(desired, nil)
			access.Notify(changes)

			return true, nil
		end,
		Prepare = function(
			updates: { Types.ProfileUpdate },
			graph: InputTypes.InputGraphSnapshot?
		): (Types.PreparedProfileGraph?, string?)
			local rejection: string? = access.ValidateActor(nil)

			if rejection ~= nil then
				return nil, rejection
			end

			local desired: Graph.Catalog?, reason: string? = Updates.Prepare(
				access.Current(),
				updates,
				graph or input.GetGraphSnapshot(),
				access.Version() + 1,
				access.ValidateActor
			)

			if desired == nil then
				return nil, reason
			end

			return plans.Create(desired)
		end,
		Read = plans.Read,
		Release = function(plan: Types.PreparedProfileGraph): ()
			plans.Take(plan)
		end,
		Commit = function(plan: Types.PreparedProfileGraph, selection: Types.ActorPublication?): (boolean, string?)
			if input.GetCommitContext() == nil then
				return false, "InputCommitFenceRequired"
			end

			local desired: Graph.Catalog? = plans.Read(plan)

			if desired == nil then
				return false, "InvalidProfileGraph"
			end

			for actor in desired do
				if not access.Available(actor) then
					return false, "ActorViewUnavailable"
				end
			end

			if not Graph.Validate(desired, input.GetGraphSnapshot()) then
				return false, "ProfileDependencyMissing"
			end

			publish(desired, selection)
			plans.Take(plan)

			return true, nil
		end,
		Select = function(actor: ActorTypes.ActorView?): ()
			publish(access.Current(), { actor = actor })
		end,
		Clear = plans.Clear,
	}
end

return Publication
