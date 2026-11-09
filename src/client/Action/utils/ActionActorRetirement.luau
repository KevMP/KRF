--!strict
local Types = require(script.Parent.Parent.types)
local ActorTypes = require(script.Parent.Parent.Parent.Actor.types)
local InputTypes = require(script.Parent.Parent.Parent.Input.types)
local Graph = require(script.Parent.ActionProfileGraph)
local Transitions = require(script.Parent.ActionRouteTransitions)
local Retirement = require(script.Parent.ActionActivationRetirement)
local Observers = require(script.Parent.Parent.Parent.Parent.shared.Signal.PrivateObservers)

export type Access = {
	Current: () -> ActorTypes.ActorView?,
	IsDestroyed: () -> boolean,
	IsRetiring: (ActorTypes.ActorView) -> boolean,
	Busy: (boolean) -> (),
	Remove: (ActorTypes.ActorView) -> Graph.Graph?,
	Notify: ({ Types.EffectiveRouteTransition }) -> (),
	Report: (string) -> (),
}

local ActorRetirement = {}

-- ActorView's private invalidation barrier removes local identity first, then
-- delivers original I6 retirement through its existing after-commit mechanism.
function ActorRetirement.new(
	input: InputTypes.InputOwner,
	guard: Types.ActorSwitchGuard?,
	access: Access
): (ActorTypes.ActorView, string) -> ()
	return function(actor: ActorTypes.ActorView, reason: string): ()
		if access.IsDestroyed() then
			return
		end

		access.Busy(true)
		local retirement: Types.ActorSwitchRetirement? = nil

		if not access.IsRetiring(actor) then
			local failure: string?

			retirement, failure =
				Retirement.Prepare(guard, actor, if access.Current() == actor then nil else access.Current())

			if failure ~= nil then
				access.Report(failure)
			end
		end

		local previous: Graph.Graph? = access.Remove(actor)

		if retirement ~= nil and not Observers.Run(retirement.Commit) then
			access.Report("ActorRetirementCommitFailed")
			retirement = nil
		end

		local graph: InputTypes.InputGraphSnapshot = input.GetGraphSnapshot()
		access.Notify(Transitions.Diff(actor, previous, nil, graph, graph, reason))

		if retirement ~= nil and not Observers.Run(retirement.AfterCommit) then
			access.Report("ActorRetirementAfterCommitFailed")
		end

		access.Busy(false)
	end
end

return ActorRetirement
