--!strict
local Streams = require(script.Parent.ActorRecipientStream)
type Stream = Streams.Stream

local ActorStreamOrder = {}

local function exchange(heap: { Stream }, first: number, second: number): ()
	heap[first], heap[second] = heap[second], heap[first]
	heap[first].orderIndex, heap[second].orderIndex = first, second
end

local function repair(heap: { Stream }, index: number): ()
	while index > 1 do
		local parent = math.floor(index / 2)

		if heap[parent].pendingOrder <= heap[index].pendingOrder then
			break
		end

		exchange(heap, parent, index)
		index = parent
	end

	while index * 2 <= #heap do
		local child = index * 2

		if child < #heap and heap[child + 1].pendingOrder < heap[child].pendingOrder then
			child += 1
		end

		if heap[index].pendingOrder <= heap[child].pendingOrder then
			break
		end

		exchange(heap, index, child)
		index = child
	end
end

-- The index contains live earliest causal positions, not publication payloads.
-- At most U32 handles exist per connection: each direction traverses <=32 levels.
function ActorStreamOrder.Update(heap: { Stream }, stream: Stream): ()
	local order = stream:GetNextOrder()
	local index = stream.orderIndex

	if order == nil then
		if index == 0 then
			return
		end

		local last = table.remove(heap) :: Stream

		stream.orderIndex = 0

		if last ~= stream then
			heap[index] = last
			last.orderIndex = index
			repair(heap, index)
		end

		return
	end

	stream.pendingOrder = order

	if index == 0 then
		table.insert(heap, stream)
		index = #heap
		stream.orderIndex = index
	end

	repair(heap, index)
end

function ActorStreamOrder.HasWorkThrough(heap: { Stream }, order: number): boolean
	return #heap > 0 and heap[1].pendingOrder <= order
end

return ActorStreamOrder
