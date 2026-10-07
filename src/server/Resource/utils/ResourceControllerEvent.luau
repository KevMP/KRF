--!strict
local ResourceTypes = require(script.Parent.Parent.types)
local SignalTypes = require(script.Parent.Parent.Parent.Parent.shared.Signal.types)

type ResourceChange = ResourceTypes.ResourceChange
export type ResourceEventJournal = {
	Queue: (self: ResourceEventJournal, change: ResourceChange) -> (),
	BeginBatch: (self: ResourceEventJournal) -> (),
	FinishBatch: (self: ResourceEventJournal) -> (),
	Drain: (self: ResourceEventJournal) -> (),
	Destroy: (self: ResourceEventJournal) -> (),
}

local ResourceControllerEvent = {}

function ResourceControllerEvent.new(
	ownedSignals: SignalTypes.OwnedSignals,
	changedSignal: SignalTypes.Signal<ResourceChange>
): ResourceEventJournal
	local journal: ResourceEventJournal = {} :: ResourceEventJournal
	local pending: { [number]: ResourceChange } = {}
	local batched: { [string]: ResourceChange } = {}
	local head: number = 1
	local tail: number = 0
	local batchDepth: number = 0
	local drainDepth: number = 0
	local destroyed: boolean = false

	local function enqueue(change: ResourceChange): ()
		if
			change.currentOldValue == change.currentNewValue
			and change.minOldValue == change.minNewValue
			and change.maxOldValue == change.maxNewValue
		then
			return
		end
		tail += 1
		pending[tail] = change
	end

	function journal:Queue(change: ResourceChange): ()
		if destroyed then
			return
		end
		if batchDepth == 0 then
			enqueue(change)
			return
		end
		local previous: ResourceChange? = batched[change.resourceId]
		if previous == nil then
			batched[change.resourceId] = change
		else
			previous.currentNewValue = change.currentNewValue
			previous.minNewValue = change.minNewValue
			previous.maxNewValue = change.maxNewValue
		end
	end

	function journal:BeginBatch(): ()
		assert(not destroyed, "ResourceControllerDestroyed")
		batchDepth += 1
	end

	function journal:FinishBatch(): ()
		assert(batchDepth > 0, "ResourceMutationBatchNotOpen")
		batchDepth -= 1
		if batchDepth > 0 then
			return
		end
		-- One transaction publishes net changes in Resource-id order, independent
		-- of first-mutation order. Append behind every older pending transaction.
		local ids: { string } = {}
		for id: string in batched do
			table.insert(ids, id)
		end
		table.sort(ids)
		for _, id: string in ids do
			enqueue(batched[id])
		end
		table.clear(batched)
	end

	function journal:Drain(): ()
		if destroyed or batchDepth > 0 or head > tail then
			return
		end
		drainDepth += 1
		ownedSignals:WithDeferredDestroy(function()
			while not destroyed and head <= tail do
				local change: ResourceChange = pending[head]
				-- Remove before issuing the signal: recursive drains can never replay it.
				pending[head] = nil
				head += 1
				changedSignal:Fire(change)
			end
		end)
		drainDepth -= 1
		if drainDepth == 0 then
			table.clear(pending)
			head = 1
			tail = 0
		end
	end

	function journal:Destroy(): ()
		destroyed = true
		table.clear(batched)
		table.clear(pending)
	end

	return journal
end

return ResourceControllerEvent
