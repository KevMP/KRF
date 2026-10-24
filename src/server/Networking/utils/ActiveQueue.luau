--!strict
-- Removable active membership. Nodes are owned by a connection or stream and reused.
export type Node<T> = { value: T, previous: Node<T>?, following: Node<T>?, queue: Queue<T>? }
export type Queue<T> = { first: Node<T>?, last: Node<T>?, count: number }

local ActiveQueue = {}

function ActiveQueue.new<T>(): Queue<T>
	return { count = 0 }
end

function ActiveQueue.node<T>(value: T): Node<T>
	return { value = value }
end

function ActiveQueue.Push<T>(queue: Queue<T>, node: Node<T>): ()
	if node.queue ~= nil then
		return
	end

	node.queue, node.previous = queue, queue.last

	if queue.last ~= nil then
		queue.last.following = node
	else
		queue.first = node
	end

	queue.last = node
	queue.count += 1
end

function ActiveQueue.Remove<T>(node: Node<T>): ()
	local queue = node.queue

	if queue == nil then
		return
	end

	if node.previous ~= nil then
		node.previous.following = node.following
	else
		queue.first = node.following
	end

	if node.following ~= nil then
		node.following.previous = node.previous
	else
		queue.last = node.previous
	end

	queue.count -= 1
	node.queue, node.previous, node.following = nil, nil, nil
end

function ActiveQueue.Pop<T>(queue: Queue<T>): T?
	local first = queue.first

	if first == nil then
		return nil
	end

	ActiveQueue.Remove(first)

	return first.value
end

return ActiveQueue
