--!strict
local Constants = require(script.Parent.InputConstants)

export type Owner = {
	Depth: () -> number,
	Unavailable: () -> string?,
	IsTerminal: () -> boolean,
	IsFaulted: () -> boolean,
	CanDispatch: () -> boolean,
	IsBusy: () -> boolean,
	IsFenced: () -> boolean,
	IsValidating: () -> boolean,
	IsCoordinating: () -> boolean,
	IsSafetyPending: () -> boolean,
	SetSafetyPending: (boolean) -> (),
	BeginCoordination: () -> (boolean, string?),
	EndCoordination: () -> (),
	SetFenced: (boolean) -> (),
	SetValidating: (boolean) -> (),
	EnterDispatch: () -> (),
	LeaveDispatch: () -> (),
	Fault: () -> boolean,
	Destroy: () -> boolean,
	Queue: (() -> ()) -> (boolean, string?),
	AfterCommit: (() -> ()) -> (boolean, string?),
	DrainAfterCommit: () -> (),
	Observe: (() -> ()) -> (),
	Flush: () -> (),
	Clear: () -> (),
}

local Gate = {}

-- One input-owned barrier. Mandatory follow-ups drain before source mutations.
function Gate.new(isReady: () -> boolean, report: (string) -> ()): Owner
	local destroyed: boolean = false
	local faulted: boolean = false
	local validating: boolean = false
	local fenced: boolean = false
	local coordinating: boolean = false
	local safetyPending: boolean = false
	local dispatchDepth: number = 0
	local draining: boolean = false
	local pending: { () -> () } = {}
	local committed: { () -> () } = {}
	local observations: { () -> () } = {}
	local owner: Owner

	local function unavailable(): string?
		if destroyed or not isReady() then
			return "ClientNotReady"
		end

		if faulted then
			return "InputRuntimeFaulted"
		end

		if validating then
			return "InputMutationDuringValidation"
		end

		return nil
	end

	local function enqueue(queue: { () -> () }, callback: () -> ()): (boolean, string?)
		if #queue >= Constants.MAX_PENDING_MUTATIONS then
			return false, "InputMutationQueueLimitExceeded"
		end

		table.insert(queue, callback)

		return true, nil
	end

	local function run(callback: () -> ()): ()
		local success: boolean, reason: unknown = pcall(callback)

		if not success then
			report(tostring(reason))
		end
	end

	local function drainCommitted(): ()
		local total: number = 0

		while #committed > 0 and not destroyed and not faulted do
			total += 1

			if total > Constants.MAX_PENDING_MUTATIONS then
				table.clear(committed)
				report("InputMutationQueueLimitExceeded")
				break
			end

			run(assert(table.remove(committed, 1), "Expected committed callback"))
		end
	end

	owner = {
		Depth = function(): number
			return dispatchDepth
		end,
		Unavailable = unavailable,
		IsTerminal = function(): boolean
			return destroyed or faulted
		end,
		IsFaulted = function(): boolean
			return faulted
		end,
		CanDispatch = function(): boolean
			return not destroyed and not faulted and isReady()
		end,
		IsBusy = function(): boolean
			return fenced or dispatchDepth > 0
		end,
		IsFenced = function(): boolean
			return fenced
		end,
		IsValidating = function(): boolean
			return validating
		end,
		IsCoordinating = function(): boolean
			return coordinating
		end,
		IsSafetyPending = function(): boolean
			return safetyPending
		end,
		SetSafetyPending = function(value: boolean): ()
			safetyPending = value
		end,
		BeginCoordination = function(): (boolean, string?)
			local rejection: string? = unavailable()

			if rejection ~= nil then
				return false, rejection
			end

			if coordinating or fenced or dispatchDepth > 0 then
				return false, "DispatchInProgress"
			end

			coordinating = true

			return true, nil
		end,
		EndCoordination = function(): ()
			coordinating = false
			local batch: { () -> () } = observations
			observations = {}

			for _, callback in batch do
				task.defer(callback)
			end

			owner.Flush()
		end,
		SetFenced = function(value: boolean): ()
			fenced = value
		end,
		SetValidating = function(value: boolean): ()
			validating = value
		end,
		EnterDispatch = function(): ()
			dispatchDepth += 1
		end,
		LeaveDispatch = function(): ()
			dispatchDepth -= 1
		end,
		Fault = function(): boolean
			if faulted or destroyed then
				return false
			end

			faulted = true
			fenced = true

			return true
		end,
		Destroy = function(): boolean
			if destroyed then
				return false
			end

			destroyed = true

			return true
		end,
		Queue = function(callback: () -> ()): (boolean, string?)
			return enqueue(pending, callback)
		end,
		AfterCommit = function(callback: () -> ()): (boolean, string?)
			if destroyed or faulted then
				return false, "ClientNotReady"
			end

			if fenced or coordinating then
				return enqueue(committed, callback)
			end

			callback()

			return true, nil
		end,
		DrainAfterCommit = drainCommitted,
		Observe = function(callback: () -> ()): ()
			if coordinating then
				table.insert(observations, callback)
			else
				callback()
			end
		end,
		Flush = function(): ()
			if draining or fenced or dispatchDepth > 0 or validating or coordinating then
				return
			end

			draining = true
			drainCommitted()
			local total: number = 0

			while #pending > 0 and not destroyed and not faulted do
				total += 1

				if total > Constants.MAX_PENDING_MUTATIONS then
					table.clear(pending)
					report("InputMutationQueueLimitExceeded")
					break
				end

				run(assert(table.remove(pending, 1), "Expected pending callback"))
				drainCommitted()
			end

			draining = false
		end,
		Clear = function(): ()
			table.clear(pending)
			table.clear(committed)
			table.clear(observations)
		end,
	}

	return owner
end

return Gate
