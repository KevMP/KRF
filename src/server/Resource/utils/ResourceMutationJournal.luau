--!strict
local ResourceTypes = require(script.Parent.Parent.types)

export type ResourceMutationJournal = {
	Observe: (self: ResourceMutationJournal, observer: ResourceTypes.ResourceMutationObserver) -> () -> (),
	Touch: (self: ResourceMutationJournal, resourceId: string, kind: ResourceTypes.ResourceMutationKind) -> (),
	Commit: (self: ResourceMutationJournal) -> (),
	BeginBatch: (self: ResourceMutationJournal) -> (),
	FinishBatch: (self: ResourceMutationJournal) -> (),
	Dispatch: (self: ResourceMutationJournal, notify: () -> ()) -> (),
	RethrowFailure: (self: ResourceMutationJournal) -> (),
	Destroy: (self: ResourceMutationJournal) -> (),
}

local ResourceMutationJournal = {}

-- Keep private delivery synchronous without restricting public Signal listeners.
local function runObserver(callback: (...any) -> (), ...: any): (boolean, any)
	local observerThread: thread = coroutine.create(callback)
	local success: boolean, failure: any = coroutine.resume(observerThread, ...)

	if coroutine.status(observerThread) ~= "dead" then
		pcall(task.cancel, observerThread)
		pcall(coroutine.close, observerThread)

		return false, "ResourceMutationObserverYielded"
	end

	return success, failure
end

-- A meaningful touch must survive later regeneration in the same transaction.
local priority: { [ResourceTypes.ResourceMutationKind]: number } = {
	RegenStep = 1,
	Recomputed = 2,
	Discrete = 3,
	Added = 4,
}

function ResourceMutationJournal.new(): ResourceMutationJournal
	local journal: ResourceMutationJournal = {} :: ResourceMutationJournal
	local observers: { [ResourceTypes.ResourceMutationObserver]: { includeRegenSteps: boolean } } = {}
	local regenObservers: number = 0
	local dispatchPending: boolean = false
	local touched: { [string]: ResourceTypes.ResourceMutationKind } = {}
	local batchDepth: number = 0
	local commitDepth: number = 0
	local failed: boolean = false
	local failure: any = nil
	local destroyed: boolean = false

	local function rememberFailure(success: boolean, reason: any): ()
		if not success and not failed then
			failed = true
			failure = reason
		end
	end

	function journal:Observe(observer: ResourceTypes.ResourceMutationObserver): () -> ()
		assert(not destroyed, "ResourceControllerDestroyed")
		local previous = observers[observer]

		if previous ~= nil and previous.includeRegenSteps then
			regenObservers -= 1
		end

		local registration = { includeRegenSteps = observer.includeRegenSteps ~= false }

		observers[observer] = registration

		if registration.includeRegenSteps then
			regenObservers += 1
		end

		return function(): ()
			if observers[observer] == registration then
				observers[observer] = nil

				if registration.includeRegenSteps then
					regenObservers -= 1
				end
			end
		end
	end

	function journal:Touch(resourceId: string, kind: ResourceTypes.ResourceMutationKind): ()
		if destroyed or next(observers) == nil or (kind == "RegenStep" and regenObservers == 0) then
			return
		end

		local previous: ResourceTypes.ResourceMutationKind? = touched[resourceId]

		if previous == nil or priority[kind] > priority[previous] then
			touched[resourceId] = kind
		end
	end

	function journal:Commit(): ()
		if destroyed or batchDepth > 0 or next(touched) == nil then
			return
		end

		local ids: { string } = {}

		for id: string in touched do
			table.insert(ids, id)
		end

		table.sort(ids)
		local mutations: { ResourceTypes.ResourceMutation } = {}
		local meaningful: { ResourceTypes.ResourceMutation } = {}

		for _, id: string in ids do
			local mutation: ResourceTypes.ResourceMutation = table.freeze({ resourceId = id, kind = touched[id] })
			table.insert(mutations, mutation)

			if mutation.kind ~= "RegenStep" then
				table.insert(meaningful, mutation)
			end
		end

		table.freeze(mutations)
		table.freeze(meaningful)
		table.clear(touched)
		commitDepth += 1

		for observer: ResourceTypes.ResourceMutationObserver, registration in table.clone(observers) do
			if observers[observer] == registration then
				local selected = if registration.includeRegenSteps then mutations else meaningful

				if #selected > 0 then
					dispatchPending = true
					rememberFailure(runObserver(observer.Commit, selected))
				end
			end
		end

		commitDepth -= 1
	end

	function journal:BeginBatch(): ()
		assert(not destroyed, "ResourceControllerDestroyed")
		batchDepth += 1
	end

	function journal:RethrowFailure(): ()
		if failed then
			local reason: any = failure
			failed, failure = false, nil
			error(reason, 0)
		end
	end

	function journal:FinishBatch(): ()
		assert(batchDepth > 0, "ResourceMutationBatchNotOpen")
		batchDepth -= 1
		journal:Commit()
	end

	function journal:Dispatch(notify: () -> ()): ()
		if batchDepth > 0 or commitDepth > 0 then
			return
		end

		if not dispatchPending and not failed then
			if not destroyed then
				notify()
			end

			return
		end

		dispatchPending = false

		-- Authority is already installed. Finish notification delivery before
		-- surfacing observer errors, including at Property/Action dispatch boundaries.
		local dispatchFailed: boolean = failed
		local dispatchFailure: any = failure
		failed, failure = false, nil

		if not destroyed then
			rememberFailure(pcall(notify))

			for observer: ResourceTypes.ResourceMutationObserver, registration in table.clone(observers) do
				if observers[observer] == registration then
					rememberFailure(runObserver(observer.Dispatch))
				end
			end
		end

		if not dispatchFailed then
			dispatchFailed, dispatchFailure = failed, failure
		end

		failed, failure = false, nil

		if dispatchFailed then
			error(dispatchFailure, 0)
		end
	end

	function journal:Destroy(): ()
		destroyed = true
		regenObservers = 0
		table.clear(observers)
		table.clear(touched)
	end

	return journal
end

return ResourceMutationJournal
