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
	SetFenced: (enabled: boolean) -> (),
	SetValidating: (enabled: boolean) -> (),
	EnterDispatch: () -> (),
	LeaveDispatch: () -> (),
	Fault: () -> boolean,
	Destroy: () -> boolean,
	Queue: (mutation: () -> ()) -> (boolean, string?),
	Flush: () -> (),
	Clear: () -> (),
}

local Gate = {}

-- Owns the shared exclusion state; collaborators never keep competing fences.
function Gate.new(isReady: () -> boolean, report: (string) -> ()): Owner
	local destroyed: boolean = false
	local faulted: boolean = false
	local validating: boolean = false
	local fenced: boolean = false
	local dispatchDepth: number = 0
	local draining: boolean = false
	local pending: { () -> () } = {}

	return {
		Depth = function(): number
			return dispatchDepth
		end,
		Unavailable = function(): string?
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
		end,
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
		SetFenced = function(enabled: boolean): ()
			fenced = enabled
		end,
		SetValidating = function(enabled: boolean): ()
			validating = enabled
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
		Queue = function(mutation: () -> ()): (boolean, string?)
			if #pending >= Constants.MAX_PENDING_MUTATIONS then
				return false, "InputMutationQueueLimitExceeded"
			end

			table.insert(pending, mutation)

			return true, nil
		end,
		Flush = function(): ()
			if draining or fenced or dispatchDepth > 0 or validating then
				return
			end

			draining = true
			local total: number = 0

			while #pending > 0 and not destroyed and not faulted do
				total += 1

				if total > Constants.MAX_PENDING_MUTATIONS then
					report("InputMutationQueueLimitExceeded")
					table.clear(pending)
					break
				end

				local mutation: () -> () = assert(table.remove(pending, 1), "Expected queued input mutation")
				local success: boolean, reason: any = pcall(mutation)

				if not success then
					report(tostring(reason))
				end
			end

			draining = false
		end,
		Clear = function(): ()
			table.clear(pending)
		end,
	}
end

return Gate
