--!strict
local ResourceTypes = require(script.Parent.Parent.types)

export type ResourceMutationJournal = {
	Observe: (self: ResourceMutationJournal, observer: ResourceTypes.ResourceMutationObserver) -> () -> (),
	Touch: (self: ResourceMutationJournal, resourceId: string, kind: ResourceTypes.ResourceMutationKind) -> (),
	Commit: (self: ResourceMutationJournal) -> (),
	BeginBatch: (self: ResourceMutationJournal) -> (),
	FinishBatch: (self: ResourceMutationJournal) -> (),
	Dispatch: (self: ResourceMutationJournal, notify: () -> ()) -> (),
	Destroy: (self: ResourceMutationJournal) -> (),
}

local ResourceMutationJournal = {}

-- A meaningful touch must survive later regeneration in the same transaction.
local priority: { [ResourceTypes.ResourceMutationKind]: number } = {
	RegenStep = 1,
	Recomputed = 2,
	Discrete = 3,
	Added = 4,
}

function ResourceMutationJournal.new(): ResourceMutationJournal
	local journal: ResourceMutationJournal = {} :: ResourceMutationJournal
	local observers: { [ResourceTypes.ResourceMutationObserver]: boolean } = {}
	local touched: { [string]: ResourceTypes.ResourceMutationKind } = {}
	local batchDepth: number = 0
	local destroyed: boolean = false

	function journal:Observe(observer: ResourceTypes.ResourceMutationObserver): () -> ()
		assert(not destroyed, "ResourceControllerDestroyed")
		observers[observer] = true

		return function(): ()
			observers[observer] = nil
		end
	end

	function journal:Touch(resourceId: string, kind: ResourceTypes.ResourceMutationKind): ()
		if destroyed or next(observers) == nil then
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

		for _, id: string in ids do
			table.insert(mutations, table.freeze({ resourceId = id, kind = touched[id] }))
		end

		table.freeze(mutations)
		table.clear(touched)

		for observer: ResourceTypes.ResourceMutationObserver in table.clone(observers) do
			if observers[observer] then
				observer.Commit(mutations)
			end
		end
	end

	function journal:BeginBatch(): ()
		assert(not destroyed, "ResourceControllerDestroyed")
		batchDepth += 1
	end

	function journal:FinishBatch(): ()
		assert(batchDepth > 0, "ResourceMutationBatchNotOpen")
		batchDepth -= 1
		journal:Commit()
	end

	function journal:Dispatch(notify: () -> ()): ()
		if destroyed or batchDepth > 0 then
			return
		end

		notify()

		for observer: ResourceTypes.ResourceMutationObserver in table.clone(observers) do
			if observers[observer] then
				observer.Dispatch()
			end
		end
	end

	function journal:Destroy(): ()
		destroyed = true
		table.clear(observers)
		table.clear(touched)
	end

	return journal
end

return ResourceMutationJournal
