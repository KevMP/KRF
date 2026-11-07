--!strict
local Types = require(script.Parent.Parent.types)
local ActorTypes = require(script.Parent.Parent.Parent.Actor.types)
local Observers = require(script.Parent.Parent.Parent.Parent.shared.Signal.PrivateObservers)
local Retirement = {}

local function guardFailure(reason: string?): string
	return if reason == "Yielded" then "ActorSwitchGuardYielded" else "ActorSwitchGuardFailed"
end

local function readRevision(guard: Types.ActorSwitchGuard): (number?, string?)
	local read: boolean, failure: string?, revision: any = Observers.Run(guard.Revision)

	if not read or type(revision) ~= "number" then
		return nil, guardFailure(failure)
	end

	return revision, nil
end

-- Prepare local I6 retirement without an Action lifetime or transport owner.
-- The revision covers this decision, including deciding that nothing is active.
function Retirement.Prepare(
	guard: Types.ActorSwitchGuard?,
	previous: ActorTypes.ActorView?,
	target: ActorTypes.ActorView?
): (Types.ActorSwitchRetirement?, string?, number?)
	if guard == nil then
		return nil, nil, nil
	end

	local revision: number?, unreadable: string? = readRevision(guard)

	if revision == nil then
		return nil, unreadable, nil
	end

	local checked: boolean, failure: string?, active: any = Observers.Run(guard.HasActive)

	if not checked or type(active) ~= "boolean" then
		return nil, guardFailure(failure), nil
	end

	if not active then
		return nil, nil, revision
	end

	if guard.Prepare == nil then
		return nil, "ActivationGuardUnavailable", nil
	end

	local accepted: boolean, reason: string?, plan: any, rejection: any = Observers.Run(guard.Prepare, previous, target)

	if not accepted then
		return nil, guardFailure(reason), nil
	end

	if plan == nil then
		return nil, if type(rejection) == "string" then rejection else "ActorSwitchGuardFailed", nil
	end

	if
		type(plan) ~= "table"
		or getmetatable(plan) ~= nil
		or type(plan.Commit) ~= "function"
		or type(plan.AfterCommit) ~= "function"
	then
		return nil, "ActorSwitchGuardFailed", nil
	end

	return { Commit = plan.Commit, AfterCommit = plan.AfterCommit }, nil, revision
end

function Retirement.Validate(guard: Types.ActorSwitchGuard?, prepared: number?): string?
	if guard == nil then
		return nil
	end

	local revision: number?, unreadable: string? = readRevision(guard)

	if revision == nil then
		return unreadable
	end

	return if revision == prepared then nil else "StaleActorSwitch"
end

return Retirement
