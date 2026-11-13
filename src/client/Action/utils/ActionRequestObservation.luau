--!strict
local Types = require(script.Parent.Parent.types)
local RequestTypes = require(script.Parent.Parent.Parent.ActionRequest.types)
local Observers = require(script.Parent.Parent.Parent.Parent.shared.Signal.PrivateObservers)
local Facts = require(script.Parent.ActionObservationFacts)

export type Options = {
	Requests: RequestTypes.ClientActionRequestRuntime?,
	Now: () -> number,
	Publish: (Types.ActionRequestEvent) -> (),
	Report: (string) -> (),
	Measure: (() -> number)?,
}

local Observation = {}
local MAX_ORDINAL: number = 9007199254740991
local MAX_OBSERVER_SECONDS: number = 0.002

-- Owns only emission order and subscriptions. I5 retains request correlation;
-- I6 retains input ownership. Their causal staging is already outside egress.
function Observation.new(options: Options): Types.ActionObservationOwner
	local measure: () -> number = options.Measure or os.clock

	local observers =
		Observers.new(16, "ActionRequestObserverLimitExceeded") :: Observers.Registry<(Types.ActionRequestEvent) -> ()>

	local ordinal: number = 0
	local destroyed: boolean = false
	local exhausted: boolean = false
	local stopInput: (() -> ())? = nil
	local stopAdmission: (() -> ())? = nil
	local stopOutcome: (() -> ())? = nil
	local requestSource: RequestTypes.ClientActionRequestRuntime? = nil
	local reported: { [string]: boolean } = {}
	local disconnectByEntry: { [Observers.Entry<(Types.ActionRequestEvent) -> ()>]: () -> () } = {}

	local function report(reason: string): ()
		if not reported[reason] then
			reported[reason] = true
			options.Report(reason)
		end
	end

	local function emit(fact: Types.ActionRequestEvent): ()
		for _, entry in observers.Snapshot() do
			if not destroyed and entry.active then
				local disconnect = assert(disconnectByEntry[entry], "Expected owned observation subscription")
				local started: number = measure()

				local success: boolean, failure: string? = Observers.RunGuarded(entry.callback, function(): ()
					disconnect()
					report("ActionObservationObserverReentered")
				end, fact)

				if not success or measure() - started > MAX_OBSERVER_SECONDS then
					disconnect()

					report(
						if success
							then "ActionObservationObserverOverBudget"
							elseif failure == "Yielded" then "ActionObservationObserverYielded"
							else "ActionObservationObserverFaulted"
					)
				end
			end
		end

		if not destroyed then
			options.Publish(fact)
		end
	end

	local function metadata(): Types.ObservationMetadata?
		if destroyed or exhausted then
			return nil
		end

		if ordinal >= MAX_ORDINAL then
			exhausted = true
			observers.Destroy()
			table.clear(disconnectByEntry)
			report("ActionObservationOrdinalExhausted")

			return nil
		end

		ordinal += 1

		return { eventOrdinal = ordinal, observedAt = options.Now() }
	end

	local function admission(value: RequestTypes.ActionRequestAdmission): ()
		local observation = metadata()

		if observation ~= nil then
			emit(Facts.Admitted(value, observation))
		end
	end

	local function outcome(value: RequestTypes.ActionRequestOutcome): ()
		if value.status == "Accepted" and value.admission.kind == "Start" and value.sequenceId == nil then
			report("ActionObservationSequenceMissing")

			return
		end

		local observation = metadata()

		if observation ~= nil then
			emit(Facts.Outcome(value, observation))
		end
	end

	local function transition(value: Types.ActionInputDecision): ()
		local observation = metadata()

		if observation ~= nil then
			emit(Facts.Transition(value, observation))
		end
	end

	local function destroy(): ()
		if destroyed then
			return
		end

		destroyed = true

		if stopInput ~= nil then
			stopInput()
			stopInput = nil
		end

		if stopAdmission ~= nil then
			stopAdmission()
		end

		if stopOutcome ~= nil then
			stopOutcome()
		end

		observers.Destroy()
		table.clear(disconnectByEntry)
	end

	local function setRequests(requests: RequestTypes.ClientActionRequestRuntime): ()
		if destroyed or requestSource == requests then
			return
		end

		assert(requestSource == nil, "ActionObservationRequestsAlreadyBound")
		local first: () -> () = requests:ObserveAdmissions(admission)
		local second: (() -> ())? = nil

		local accepted: boolean, failure: any = pcall(function(): ()
			second = requests:ObserveOutcomes(outcome)
		end)

		if not accepted then
			first()
			error(failure, 0)
		end

		stopAdmission = first
		stopOutcome = assert(second, "Expected request outcome subscription")
		requestSource = requests
	end

	local success: boolean, failure: any = pcall(function(): ()
		if options.Requests ~= nil then
			setRequests(options.Requests)
		end
	end)

	if not success then
		destroy()
		error(failure, 0)
	end

	return {
		Observe = function(callback): () -> ()
			if destroyed or exhausted then
				return function() end
			end

			local disconnect = observers.Add(callback)
			local snapshot = observers.Snapshot()
			local entry = snapshot[#snapshot]

			local function remove(): ()
				disconnect()
				disconnectByEntry[entry] = nil
			end

			disconnectByEntry[entry] = remove

			return remove
		end,
		SetInput = function(owner): ()
			if stopInput ~= nil then
				stopInput()
				stopInput = nil
			end

			if not destroyed and owner ~= nil then
				stopInput = owner.ObserveDecisions(transition)
			end
		end,
		SetRequests = setRequests,
		SetOrdinalForTests = function(value): ()
			ordinal = value
		end,
		Destroy = destroy,
	}
end

return Observation
