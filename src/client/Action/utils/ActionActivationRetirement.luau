--!strict
local Types = require(script.Parent.Parent.types)
local ActorTypes = require(script.Parent.Parent.Parent.Actor.types)
local Observers = require(script.Parent.Parent.Parent.Parent.shared.Signal.PrivateObservers)
local Retirement = {}

-- Prepare local I6 retirement without an Action lifetime or transport owner.
function Retirement.Prepare(
	guard: Types.ActorSwitchGuard?,
	previous: ActorTypes.ActorView?,
	target: ActorTypes.ActorView?
): (Types.ActorSwitchRetirement?, string?)
	if guard == nil then
		return nil, nil
	end

	local checked: boolean, failure: string?, active: any = Observers.Run(guard.HasActive)

	if not checked or type(active) ~= "boolean" then
		return nil, if failure == "Yielded" then "ActorSwitchGuardYielded" else "ActorSwitchGuardFailed"
	end

	if not active then
		return nil, nil
	end

	if guard.Prepare == nil then
		return nil, "ActivationGuardUnavailable"
	end

	local accepted: boolean, reason: string?, plan: any, rejection: any = Observers.Run(guard.Prepare, previous, target)

	if not accepted then
		return nil, if reason == "Yielded" then "ActorSwitchGuardYielded" else "ActorSwitchGuardFailed"
	end

	if plan == nil then
		return nil, if type(rejection) == "string" then rejection else "ActorSwitchGuardFailed"
	end

	if
		type(plan) ~= "table"
		or getmetatable(plan) ~= nil
		or type(plan.Commit) ~= "function"
		or type(plan.AfterCommit) ~= "function"
	then
		return nil, "ActorSwitchGuardFailed"
	end

	return { Commit = plan.Commit, AfterCommit = plan.AfterCommit }, nil
end

return Retirement
