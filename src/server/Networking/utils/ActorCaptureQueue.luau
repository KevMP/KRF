--!strict
local ActiveQueue = require(script.Parent.ActiveQueue)
local Connections = require(script.Parent.ActorRecipientConnection)
local Streams = require(script.Parent.ActorRecipientStream)
local WorkBudget = require(script.Parent.ReliableWorkBudget)
type Connection = Connections.Connection
type Stream = Streams.Stream

local CaptureQueue = {}
CaptureQueue.__index = CaptureQueue

type State = { queue: ActiveQueue.Queue<Connection>, current: (Connection) -> boolean }

export type Runtime = typeof(setmetatable({} :: State, CaptureQueue))

function CaptureQueue.new(current: (Connection) -> boolean): Runtime
	return setmetatable({ queue = ActiveQueue.new(), current = current }, CaptureQueue)
end

-- Reference-only opportunity membership. Payloads remain in each stream's N3
-- queue; capture itself still runs through Prepare under the same causal gate.
function CaptureQueue.Index(self: Runtime, connection: Connection, stream: Stream): ()
	if stream:NeedsCapture() and stream:CanCapture() then
		local node: ActiveQueue.Node<Stream>? = stream.captureNode

		if node == nil then
			local created: ActiveQueue.Node<Stream> = ActiveQueue.node(stream :: Stream)
			stream.captureNode, node = created, created
		end

		assert(node ~= nil, "Expected capture stream node")
		ActiveQueue.Push(connection.captures, node)
		local owner: ActiveQueue.Node<Connection>? = connection.captureNode

		if owner == nil then
			local created: ActiveQueue.Node<Connection> = ActiveQueue.node(connection :: Connection)
			connection.captureNode, owner = created, created
		end

		assert(owner ~= nil, "Expected capture connection node")
		ActiveQueue.Push(self.queue, owner)
	else
		if stream.captureNode ~= nil then
			ActiveQueue.Remove(stream.captureNode)
		end

		if connection.captures.count == 0 and connection.captureNode ~= nil then
			ActiveQueue.Remove(connection.captureNode)
		end
	end
end

function CaptureQueue.Claim(self: Runtime, connection: Connection, stream: Stream, work: WorkBudget.Budget): boolean
	if
		self.current(connection) == false
		or not stream:CanCapture()
		or self.queue.first == nil
		or self.queue.first.value ~= connection
		or connection.captures.first == nil
		or connection.captures.first.value ~= stream
		or not WorkBudget.Take(work, "captures")
	then
		return false
	end

	ActiveQueue.Pop(connection.captures)
	ActiveQueue.Pop(self.queue)

	if connection.captures.count > 0 then
		ActiveQueue.Push(self.queue, connection.captureNode :: ActiveQueue.Node<Connection>)
	end

	return true
end

function CaptureQueue.Yield(self: Runtime, connection: Connection, stream: Stream): ()
	if not self.current(connection) or not stream:NeedsCapture() then
		return
	end

	if connection.captures.first ~= nil and connection.captures.first.value == stream then
		ActiveQueue.Pop(connection.captures)
		ActiveQueue.Push(connection.captures, stream.captureNode :: ActiveQueue.Node<Stream>)
	end

	if self.queue.first ~= nil and self.queue.first.value == connection then
		ActiveQueue.Pop(self.queue)
		ActiveQueue.Push(self.queue, connection.captureNode :: ActiveQueue.Node<Connection>)
	end
end

function CaptureQueue.Prioritize(
	self: Runtime,
	active: ActiveQueue.Queue<Connection>,
	work: WorkBudget.Budget,
	maxRecords: number
): ()
	if
		maxRecords < 2
		or self.queue.first == nil
		or not WorkBudget.Available(work, "captures")
		or not WorkBudget.Take(work, "priorities")
	then
		return
	end

	local connection = self.queue.first.value
	local first = connection.captures.first
	assert(first ~= nil, "Expected indexed capture opportunity")
	local stream = first.value
	local boundary = connection.egress.queue[1]

	if boundary ~= nil and not stream:HasWorkThrough(boundary.order) then
		self:Yield(connection, stream)

		return
	end

	local node, owner = stream.queueNode, connection.node

	if node ~= nil and owner ~= nil and node.queue == connection.active and owner.queue == active then
		-- One promoted capture opportunity cannot consume the whole record budget;
		-- all actual preparation/serialization still uses the normal bounded drain.
		ActiveQueue.Prioritize(connection.active, node)
		ActiveQueue.Prioritize(active, owner)
	end
end

return CaptureQueue
