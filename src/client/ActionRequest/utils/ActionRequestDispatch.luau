--!strict
local Types = require(script.Parent.Parent.types)
local ActorTypes = require(script.Parent.Parent.Parent.Actor.types)
local Facts = require(script.Parent.ActionRequestFacts)

export type Owner = {
	Send: (
		string,
		ActorTypes.ActorView?,
		any,
		(number) -> Types.ActionRequestAdmission,
		(number) -> (),
		((Types.ActionRequestAdmission) -> ())?
	) -> (number?, string?),
	Stage: (Facts.Fact) -> (),
	AfterObservations: (() -> ()) -> (),
}

local Dispatch = {}

-- Owns the irreversible command admission fence and post-egress publication.
-- Correlation changes are explicit reserve/rollback callbacks, never owner access.
function Dispatch.new(commands: Types.ActionRequestCommandPort, facts: Facts.Owner): Owner
	local function afterEgress(callback: () -> ()): ()
		if commands.AfterEgress ~= nil then
			commands.AfterEgress(callback)
		else
			callback()
		end
	end

	local function send(
		commandId: string,
		actor: ActorTypes.ActorView?,
		request: any,
		admit: (number) -> Types.ActionRequestAdmission,
		rollback: (number) -> (),
		committed: ((Types.ActionRequestAdmission) -> ())?
	): (number?, string?)
		local admitted: Types.ActionRequestAdmission? = nil
		local fact: Facts.Fact? = nil

		local requestId: number?, reason: string? = commands.SendAdmitted(
			commandId,
			actor,
			request,
			function(id: number): boolean
				local reserved: Types.ActionRequestAdmission = admit(id)

				local staged: Facts.Fact =
					{ admission = reserved, original = reserved.originalStartRequestId, ready = false }

				admitted, fact = reserved, staged
				facts.Stage(staged)

				return true
			end,
			function(): ()
				-- N9 has irreversibly admitted this command. Observation may now drain
				-- after egress, including Closing reentry before SendAdmitted returns.
				assert(fact, "Expected staged admission").ready = true

				if committed ~= nil then
					committed(assert(admitted, "Expected reserved request correlation"))
				end
			end
		)

		local staged: Facts.Fact? = fact

		if requestId == nil then
			local reserved: Types.ActionRequestAdmission? = admitted

			if reserved ~= nil then
				rollback(reserved.requestId)
			end

			if staged ~= nil then
				facts.Withdraw(staged)
			end

			return nil, reason or "CommandAdmissionRefused"
		end

		assert(staged ~= nil, "ActionRequestAdmissionMissing")

		afterEgress(function(): ()
			facts.Commit(staged)
		end)

		return requestId, nil
	end

	return {
		Send = send,
		Stage = function(fact): ()
			facts.Stage(fact)
			afterEgress(facts.Drain)
		end,
		AfterObservations = function(callback): ()
			afterEgress(function(): ()
				facts.AfterDrain(callback)
			end)
		end,
	}
end

return Dispatch
