--!strict
local Types = require(script.Parent.Parent.types)
local SharedNetworkingTypes = require(script.Parent.Parent.Parent.Parent.shared.Networking.types)
local Metrics = require(script.Parent.Parent.Parent.Parent.shared.Networking.utils.NetworkingMetrics)
local ActiveQueue = require(script.Parent.ActiveQueue)
local Connections = require(script.Parent.ActorRecipientConnection)
local Streams = require(script.Parent.ActorRecipientStream)
local CaptureQueue = require(script.Parent.ActorCaptureQueue)
local Packets = require(script.Parent.ActorPacketBatch)
local WorkBudget = require(script.Parent.ReliableWorkBudget)
type Connection = Connections.Connection
type Stream = Streams.Stream

local Delivery = {}
Delivery.__index = Delivery

type State = {
	diagnostics: SharedNetworkingTypes.DiagnosticCollector?,
	codec: SharedNetworkingTypes.ActorStreamCodec,
	current: (Connection) -> boolean,
	send: (Player, buffer) -> (boolean, string?),
	closeTransport: ((Player, string) -> ())?,
	options: Types.ActorAwarenessOptions,
	close: (Player) -> (),
	backlog: Types.ReliableBacklog,
	active: ActiveQueue.Queue<Connection>,
	captures: CaptureQueue.Runtime,
	deferred: { Stream },
	waiting: { Connection },
	epoch: number,
	work: WorkBudget.Budget?,
	stepping: boolean,
	destroyed: boolean,
}

export type Runtime = typeof(setmetatable({} :: State, Delivery))

local function observeActive(connection: Connection): ()
	local owner = connection.diagnostics

	if owner ~= nil then
		local value = if #connection.orders > 0 or #connection.egress.queue > 0 then 1 else 0

		if owner:GetCurrent("reliableActiveConnections") ~= value then
			Metrics.Set(owner, "reliableActiveConnections", value)
		end
	end
end

function Delivery.new(
	codec: SharedNetworkingTypes.ActorStreamCodec,
	current: (Connection) -> boolean,
	send: (Player, buffer) -> (boolean, string?),
	closeTransport: ((Player, string) -> ())?,
	options: Types.ActorAwarenessOptions,
	backlog: Types.ReliableBacklog,
	close: (Player) -> (),
	diagnostics: SharedNetworkingTypes.DiagnosticCollector?
): Runtime
	return setmetatable({
		codec = codec,
		current = current,
		send = send,
		closeTransport = closeTransport,
		options = options,
		backlog = backlog,
		close = close,
		diagnostics = diagnostics,
		active = ActiveQueue.new(),
		captures = CaptureQueue.new(current),
		deferred = {},
		waiting = {},
		epoch = 0,
		stepping = false,
		destroyed = false,
	}, Delivery)
end

function Delivery.Activate(self: Runtime, connection: Connection, stream: Stream): ()
	if not self.current(connection) then
		return
	end

	Connections.UpdateOrder(connection, stream)

	if stream:NeedsCapture() or (stream.captureNode ~= nil and stream.captureNode.queue ~= nil) then
		self.captures:Index(connection, stream)
	end

	if stream.active or not stream:HasWork() then
		return
	end

	stream.active = true

	local node: ActiveQueue.Node<Stream>? = stream.queueNode

	if node == nil then
		local created: ActiveQueue.Node<Stream> = ActiveQueue.node(stream :: Stream)

		stream.queueNode = created
		node = created
	end

	assert(node ~= nil, "Expected active stream node")

	if node.queue ~= connection.active then
		ActiveQueue.Push(connection.active, node)
	end

	self:Queue(connection)
end

-- Reference-only opportunity membership. Payloads remain in each stream's N3
-- queue; capture itself still runs through Prepare under the same causal gate.
function Delivery.Queue(self: Runtime, connection: Connection): ()
	if not self.current(connection) then
		return
	end

	observeActive(connection)
	local node: ActiveQueue.Node<Connection>? = connection.node

	if node ~= nil and node.queue == self.active then
		return
	end

	if node == nil then
		local created: ActiveQueue.Node<Connection> = ActiveQueue.node(connection :: Connection)

		connection.node = created
		node = created
	end

	assert(node ~= nil, "Expected active connection node")
	ActiveQueue.Push(self.active, node)
end

function Delivery._drain(self: Runtime, batch: Packets.Runtime, work: WorkBudget.Budget): ()
	self.captures:Prioritize(self.active, work, batch.records)

	while self.active.count > 0 and batch.records > 0 and batch.bytes > 0 and WorkBudget.Take(work, "connections") do
		local connection = assert(ActiveQueue.Pop(self.active))

		work.connection = connection.diagnostics

		if connection.diagnostics ~= nil then
			local count = (work.byConnection[connection.diagnostics] or 0) + 1

			work.byConnection[connection.diagnostics] = count
			Metrics.Observe(connection.diagnostics, "reliablePumpWorkUnits", count)
		end

		Metrics.Count(connection.diagnostics, "reliableConnectionVisits", 1)

		if connection.waitEpoch ~= self.epoch then
			connection.waitEpoch = self.epoch
			table.insert(self.waiting, connection)
		end

		local proceed, sentResult = batch:SendResult(connection, work)

		if not proceed then
			break
		end

		if not self.current(connection) then
			continue
		end

		if batch.records <= 0 or batch.bytes <= 0 then
			break
		end

		if connection.active.count == 0 then
			if not sentResult then
				Metrics.Count(connection.diagnostics, "reliableUnproductiveInspections", 1)
			end

			if sentResult and #connection.egress.queue > 0 then
				self:Queue(connection)
			end

			continue
		end

		if
			not WorkBudget.Take(work, "streams")
			or not WorkBudget.Available(work, "prepares")
			or not WorkBudget.Available(work, "measurements")
		then
			break
		end

		local stream = assert(ActiveQueue.Pop(connection.active))
		stream:StageBaseline()
		-- Selection owns the lease until the epilogue, even when no record fits.
		table.insert(self.deferred, stream)
		batch:Stage(connection, stream, work)

		if connection.active.count > 0 then
			self:Queue(connection)
		end
	end

	batch:Flush(work)
end

function Delivery.Step(self: Runtime, maxBytes: number, maxRecords: number): ()
	if self.stepping or self.destroyed then
		return
	end

	assert(maxBytes < math.huge and maxRecords < math.huge, "InvalidReliableStepBudget")

	if maxBytes <= 0 or maxRecords <= 0 or self.active.count == 0 then
		self.work = nil

		return
	end

	local work = WorkBudget.new(math.max(0, maxRecords), self.options.workLimits, self.diagnostics)

	self.work = work
	self.epoch += 1
	self.stepping = true

	local batch =
		Packets.new(self.codec, self.current, self.send, self.close, self.closeTransport, maxBytes, maxRecords)

	local success, failure = pcall(self._drain, self, batch, work)

	-- This epilogue also runs after an injected dependency throws. Nothing staged
	-- or blocked is reselected within its pump, and remaining active work survives.
	for _, stream in self.deferred do
		stream:ReleaseStaged()
		stream.active = false
		stream.dependencies.Activate(stream)
	end

	for _, connection in self.waiting do
		if connection.active.count > 0 or #connection.egress.queue > 0 then
			self:Queue(connection)
		elseif self.current(connection) then
			observeActive(connection)
		end
	end

	if self.destroyed then
		self.backlog:Destroy()
	end

	table.clear(self.deferred)
	table.clear(self.waiting)
	self.stepping = false

	if not success then
		error(failure, 0)
	end
end

function Delivery.Destroy(self: Runtime): ()
	self.destroyed = true
	self.active = ActiveQueue.new()
	self.captures.queue = ActiveQueue.new()

	if not self.stepping then
		self.backlog:Destroy()
		self.deferred, self.waiting = {}, {}
	end
end

return Delivery
