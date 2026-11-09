--!strict
local Types = require(script.Parent.types)
local InputTypes = require(script.Parent.Parent.Input.types)
local ActionTypes = require(script.Parent.Parent.Action.types)
local Validator = require(script.Parent.ControlValidator)
local Prepared = require(script.Parent.utils.ControlPreparedChange)
local Safety = require(script.Parent.utils.ControlSafety)
local Observers = require(script.Parent.Parent.Parent.shared.Signal.PrivateObservers)

local Owner = {}

function Owner.new(
	input: InputTypes.InputOwner,
	actions: ActionTypes.ClientActionOwner,
	isReady: () -> boolean
): Types.ControlOwner
	local destroyed: boolean = false
	local applying: boolean = false
	local safety: Safety.Owner
	local owner: Types.ControlOwner

	local function status(): string?
		if destroyed or not isReady() then
			return "ClientNotReady"
		end

		local unavailable: string? = input.GetMutationStatus()

		if applying or unavailable == "InputMutationReentrant" or unavailable == "InputMutationDuringValidation" then
			return "DispatchInProgress"
		end

		return unavailable
	end

	local function finish(): (boolean, string?)
		input.DrainControlFollowUps()

		while safety.HasPending() do
			local drained: boolean, reason: string? = safety.Drain()

			if not drained then
				return false, reason
			end

			input.DrainControlFollowUps()
		end

		return true, nil
	end

	local function apply(changeSet: Types.ControlChangeSet): (boolean, string?)
		Observers.CheckReentry()
		local rejection: string? = status()

		-- A mandatory event sets the gate before its idle callback enters here.
		if rejection == "DispatchInProgress" and safety.HasPending() and not applying then
			rejection = input.GetMutationStatus(true)
		end

		if rejection ~= nil then
			return false, rejection
		end

		local entered: boolean, enterReason: string? = input.BeginControlChange()

		if not entered then
			return false, enterReason
		end

		applying = true
		local plan: Prepared.Plan? = nil

		local success: boolean, _, accepted: unknown, reason: unknown = Observers.Run(function(): (boolean, string?)
			local normalized: Validator.Normalized?, invalid: string? = Validator.Normalize(changeSet)

			if normalized == nil then
				return false, invalid
			end

			plan, invalid = Prepared.Compile(input, actions, normalized)

			if plan == nil then
				return false, invalid
			end

			if destroyed or not isReady() then
				return false, "ClientNotReady"
			end

			return actions.CommitControlledActorWithInput(
				plan.selection,
				{ input = plan.input, profiles = plan.profiles }
			)
		end)

		if plan ~= nil then
			Prepared.Release(input, actions, plan)
		end

		local cleanupRan: boolean, _, cleanupAccepted: unknown = Observers.Run(finish)

		if not success or not cleanupRan or cleanupAccepted ~= true then
			input.FailControlChange()
		end

		safety.EndCycle()
		applying = false
		input.EndControlChange()

		if destroyed or not isReady() then
			return false, "ClientNotReady"
		end

		if not success or input.GetMutationStatus(true) == "InputRuntimeFaulted" then
			return false, "InputRuntimeFaulted"
		end

		return accepted == true, if type(reason) == "string" then reason else nil
	end

	safety = Safety.new(input, function(): ()
		if not applying then
			local accepted: boolean = input.WhenIdle(function(): ()
				if not destroyed and isReady() and safety.HasPending() then
					apply({})
				end
			end)

			if not accepted then
				input.FailControlChange()
			end
		end
	end)

	owner = {
		Apply = apply,
		OnLifecycle = safety.Record,
		Destroy = function(): ()
			if destroyed then
				return
			end

			destroyed = true
			safety.Destroy()
		end,
	}

	return owner
end

return Owner
