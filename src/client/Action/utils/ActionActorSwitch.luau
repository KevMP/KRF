--!strict
local Types = require(script.Parent.Parent.types)
local ActorTypes = require(script.Parent.Parent.Parent.Actor.types)
local InputTypes = require(script.Parent.Parent.Parent.Input.types)
local Observers = require(script.Parent.Parent.Parent.Parent.shared.Signal.PrivateObservers)
local Plans = require(script.Parent.ActionPreparedPlans)
local Retirement = require(script.Parent.ActionActivationRetirement)

export type Access = {
	Current: () -> ActorTypes.ActorView?,
	Validate: (ActorTypes.ActorView?) -> string?,
	CanPublish: (ActorTypes.ActorView?) -> boolean,
	Fence: (boolean) -> (),
	Publish: (ActorTypes.ActorView?) -> (),
	Fail: () -> (),
	Report: (string) -> (),
}

export type Owner = {
	Prepare: (ActorTypes.ActorView?) -> (Types.PreparedActorSwitch?, string?),
	Commit: (Types.PreparedActorSwitch) -> (boolean, string?),
	Clear: () -> (),
	IsRetiring: (ActorTypes.ActorView) -> boolean,
}

type Switch = {
	previous: ActorTypes.ActorView?,
	target: ActorTypes.ActorView?,
	epoch: InputTypes.PreparedInputInvalidation?,
	recognition: InputTypes.PreparedRecognitionReset?,
	retirement: Types.ActorSwitchRetirement?,
	activationRevision: number?,
}

local Switching = {}

function Switching.new(input: InputTypes.InputOwner, guard: Types.ActorSwitchGuard?, access: Access): Owner
	local retiring: { [ActorTypes.ActorView]: boolean } = {}

	local function dispose(record: Switch): ()
		if record.epoch ~= nil then
			input.ReleasePrepared(record.epoch)
		end

		if record.recognition ~= nil then
			input.ReleasePrepared(record.recognition)
		end
	end

	local plans: Plans.Store<Switch> = Plans.new(dispose)

	local function prepare(target: ActorTypes.ActorView?): (Types.PreparedActorSwitch?, string?)
		local reason: string? = access.Validate(target)

		if reason ~= nil then
			return nil, reason
		end

		local record: Switch = { previous = access.Current(), target = target }

		if not plans.CanCreate() then
			return nil, "ActionPlanLimitExceeded"
		end

		if target == access.Current() then
			return plans.Create(record)
		end

		access.Fence(true)

		local success: boolean, fault: string?, prepared: any, rejection: any = Observers.Run(
			function(): (boolean, string?)
				local epoch: InputTypes.PreparedInputInvalidation?, epochReason: string? =
					input.PrepareEpochInvalidation("ActorChanged")

				if epoch == nil then
					return false, epochReason
				end

				record.epoch = epoch

				local recognition: InputTypes.PreparedRecognitionReset?, recognitionReason: string? =
					input.PrepareRecognitionReset(nil, "ActorChanged")

				if recognition == nil then
					return false, recognitionReason
				end

				record.recognition = recognition

				local retirement: Types.ActorSwitchRetirement?, retirementReason: string?, activationRevision: number? =
					Retirement.Prepare(guard, record.previous, target)

				if retirementReason ~= nil then
					return false, retirementReason
				end

				record.retirement = retirement
				record.activationRevision = activationRevision

				return true, nil
			end
		)

		access.Fence(false)

		if not success or prepared ~= true then
			dispose(record)

			return nil,
				if success
					then rejection
					else (if fault == "Yielded" then "ActorSwitchGuardYielded" else "ActorSwitchGuardFailed")
		end

		return plans.Create(record)
	end

	local function commit(token: Types.PreparedActorSwitch): (boolean, string?)
		local reason: string? = access.Validate(nil)

		if reason ~= nil then
			return false, reason
		end

		local record: Switch?, known: boolean = plans.Take(token)

		if record == nil then
			return false, if known then "StaleActorSwitch" else "InvalidActorSwitch"
		end

		reason = access.Validate(record.target)

		if reason ~= nil then
			dispose(record)

			return false, reason
		end

		if record.target == access.Current() then
			dispose(record)

			return true, nil
		end

		if record.previous ~= access.Current() then
			dispose(record)

			return false, "StaleActorSwitch"
		end

		if
			record.epoch == nil
			or record.recognition == nil
			or not input.ValidatePrepared(record.epoch)
			or not input.ValidatePrepared(record.recognition)
		then
			dispose(record)

			return false, "StaleActorSwitch"
		end

		reason = Retirement.Validate(guard, record.activationRevision)

		if reason ~= nil then
			dispose(record)

			return false, reason
		end

		access.Fence(true)

		local rejection: string? = nil
		local claimedActor: ActorTypes.ActorView? = nil
		local previousClaim: boolean? = nil

		local success: boolean, _, committed: any = Observers.Run(function(): boolean
			local epoch: InputTypes.PreparedInputInvalidation = assert(record.epoch, "Expected epoch plan")
			local published: boolean = false

			local accepted: boolean, failure: string?, phase: InputTypes.InputCommitFailurePhase? = input.CommitEpochInvalidation(
				epoch,
				function(): ()
					local completed: boolean, _, reset: any = Observers.Run(
						input.CommitPreparedRecognitionReset,
						assert(record.recognition, "Expected recognition plan")
					)

					if not completed or reset ~= true then
						return
					end

					-- Reset runs recognizer callbacks. Input is already committed, so a
					-- change here fails closed rather than rejecting.
					if Retirement.Validate(guard, record.activationRevision) ~= nil then
						return
					end

					if record.retirement ~= nil then
						if access.Current() ~= record.previous or not access.CanPublish(record.previous) then
							return
						end

						claimedActor = record.previous

						if claimedActor ~= nil then
							previousClaim = retiring[claimedActor]
							retiring[claimedActor] = true
						end

						if not Observers.Run(record.retirement.Commit) then
							return
						end
					end

					if not access.CanPublish(record.target) then
						return
					end

					local installed: boolean = Observers.Run(access.Publish, record.target)
					published = installed
				end
			)

			if not accepted and phase == "Rejected" then
				rejection = failure
			end

			return accepted and published
		end)

		dispose(record)

		local failed: boolean = not success or committed ~= true
		local rejected: boolean = success and rejection ~= nil

		if failed and not rejected then
			access.Fail()
		end

		access.Fence(false)

		if not failed and record.retirement ~= nil then
			local delivered: boolean = Observers.Run(record.retirement.AfterCommit)

			if not delivered then
				access.Report("ActorSwitchAfterCommitFailed")
			end
		end

		-- Synchronous post-commit callbacks may themselves complete another
		-- switch. Restore any enclosing claim rather than erasing it.
		if claimedActor ~= nil then
			retiring[claimedActor] = previousClaim
		end

		if failed then
			return false, if rejected then rejection else "ActorSwitchCommitFailed"
		end

		return true, nil
	end

	return {
		Prepare = prepare,
		Commit = commit,
		Clear = plans.Clear,
		IsRetiring = function(actor: ActorTypes.ActorView): boolean
			return retiring[actor] == true
		end,
	}
end

return Switching
