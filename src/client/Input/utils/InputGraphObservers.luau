--!strict
local Types = require(script.Parent.Parent.types)
local Constants = require(script.Parent.InputConstants)
local Observers = require(script.Parent.Parent.Parent.Parent.shared.Signal.PrivateObservers)
local MutationGate = require(script.Parent.InputMutationGate)

type CommitObserver = (Types.InputGraphChange) -> ()

export type Owner = {
	Validate: (graph: Types.InputGraphSnapshot, profiles: unknown) -> string?,
	Version: () -> number,
	RegisterValidator: (callback: Types.GraphValidator) -> () -> (),
	ObserveCommit: (callback: CommitObserver) -> () -> (),
	Notify: (change: Types.InputGraphChange, strict: boolean) -> (),
	Destroy: () -> (),
}

local GraphObservers = {}

function GraphObservers.new(gate: MutationGate.Owner): Owner
	local version: number = 0

	local validators: Observers.Registry<Types.GraphValidator> = Observers.new(
		Constants.MAX_GRAPH_VALIDATORS,
		"InputValidatorLimitExceeded"
	) :: Observers.Registry<Types.GraphValidator>

	local commits: Observers.Registry<CommitObserver> = Observers.new(
		Constants.MAX_COMMIT_OBSERVERS,
		"InputCommitObserverLimitExceeded"
	) :: Observers.Registry<CommitObserver>

	return {
		Validate = function(nextGraph: Types.InputGraphSnapshot, profiles: unknown): string?
			gate.SetValidating(true)
			local failure: string? = nil

			for _, entry in validators.Snapshot() do
				if not entry.active then
					continue
				end

				local success: boolean, reason: string?, accepted: unknown, rejection: unknown =
					Observers.Run(entry.callback, nextGraph, profiles)

				if not success then
					failure = if reason == "Yielded" then "InputGraphValidatorYielded" else "InputGraphValidatorFailed"
				elseif type(accepted) ~= "boolean" or (rejection ~= nil and type(rejection) ~= "string") then
					failure = "InvalidGraphValidatorResult"
				elseif not accepted then
					failure = rejection or "InputGraphRejected"
				end

				if failure ~= nil then
					break
				end
			end

			gate.SetValidating(false)

			return failure
		end,
		Version = function(): number
			return version
		end,
		RegisterValidator = function(callback: Types.GraphValidator): () -> ()
			assert(type(callback) == "function", "InvalidInputObserver")
			local stop: () -> () = validators.Add(callback)
			version += 1
			local active: boolean = true

			return function(): ()
				if active then
					active = false
					version += 1
					stop()
				end
			end
		end,
		ObserveCommit = function(callback: CommitObserver): () -> ()
			assert(type(callback) == "function", "InvalidInputObserver")

			return commits.Add(callback)
		end,
		Notify = function(change: Types.InputGraphChange, strict: boolean): ()
			for _, entry in commits.Snapshot() do
				if entry.active then
					local success: boolean = Observers.Run(entry.callback, change)

					if not success and strict then
						error("InputCommitObserverFailed", 0)
					end
				end
			end
		end,
		Destroy = function(): ()
			validators.Destroy()
			commits.Destroy()
		end,
	}
end

return GraphObservers
