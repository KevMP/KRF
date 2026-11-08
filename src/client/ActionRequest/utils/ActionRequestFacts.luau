--!strict
local Types = require(script.Parent.Parent.types)
local Observers = require(script.Parent.Parent.Parent.Parent.shared.Signal.PrivateObservers)

export type Fact = {
	admission: Types.ActionRequestAdmission?,
	outcome: Types.ActionRequestOutcome?,
	callback: (() -> ())?,
	original: number,
	ready: boolean,
}

export type Owner = {
	Stage: (Fact) -> (),
	Commit: (Fact) -> (),
	Withdraw: (Fact) -> (),
	Drain: () -> (),
	ObserveAdmissions: ((Types.ActionRequestAdmission) -> ()) -> () -> (),
	ObserveOutcomes: ((Types.ActionRequestOutcome) -> ()) -> () -> (),
	Destroy: () -> (),
}

local Facts = {}

function Facts.new(maximum: number?): Owner
	local admissions =
		Observers.new(16, "ActionRequestObserverLimitExceeded") :: Observers.Registry<(Types.ActionRequestAdmission) -> ()>

	local outcomes =
		Observers.new(16, "ActionRequestObserverLimitExceeded") :: Observers.Registry<(Types.ActionRequestOutcome) -> ()>

	local queue: { Fact } = {}
	local draining: boolean = false
	local destroyed: boolean = false

	local function notify<T>(registry: Observers.Registry<(T) -> ()>, value: T): ()
		for _, entry in registry.Snapshot() do
			if entry.active then
				Observers.Run(entry.callback, value)
			end
		end
	end

	local function drain(): ()
		if draining then
			return
		end

		draining = true

		while not destroyed and #queue > 0 and queue[1].ready do
			local fact: Fact = assert(table.remove(queue, 1), "Expected staged request fact")

			if fact.admission ~= nil then
				notify(admissions, fact.admission)
			elseif fact.outcome ~= nil then
				notify(outcomes, fact.outcome)
			else
				Observers.Run(assert(fact.callback, "Expected request decision callback"))
			end
		end

		draining = false
	end

	return {
		Stage = function(fact: Fact): ()
			if not destroyed then
				assert(#queue < (maximum or 768), "ActionRequestFactLimitExceeded")
				table.insert(queue, fact)
			end
		end,
		Commit = function(fact: Fact): ()
			fact.ready = true
			drain()
		end,
		Drain = drain,
		Withdraw = function(fact: Fact): ()
			for index: number = #queue, 1, -1 do
				local queued: Fact = queue[index]

				if
					queued == fact
					or (fact.admission ~= nil and fact.admission.kind == "Start" and queued.original == fact.original)
				then
					table.remove(queue, index)
				end
			end

			drain()
		end,
		ObserveAdmissions = function(observer): () -> ()
			return if destroyed then function() end else admissions.Add(observer)
		end,
		ObserveOutcomes = function(observer): () -> ()
			return if destroyed then function() end else outcomes.Add(observer)
		end,
		Destroy = function(): ()
			destroyed = true
			table.clear(queue)
			admissions.Destroy()
			outcomes.Destroy()
		end,
	}
end

return Facts
