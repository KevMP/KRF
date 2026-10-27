--!strict
local Types = require(script.Parent.types)
local SharedTypes = require(script.Parent.Parent.Parent.shared.Networking.types)
local Metrics = require(script.Parent.Parent.Parent.shared.Networking.utils.NetworkingMetrics)
local Diagnostics = require(script.Parent.utils.NetworkingDiagnosticsState)
local Constants = require(script.Parent.Parent.Parent.shared.Networking.utils.CommandConstants)
local Codec = require(script.Parent.Parent.Parent.shared.Networking.CommandCodec)
local History = require(script.Parent.utils.CommandOutcomeHistory)
local Execution = require(script.Parent.utils.CommandExecution)
local CommandDiagnostics = require(script.Parent.utils.CommandDiagnostics)
local Admission = require(script.Parent.utils.CommandAdmission)
local Queue = require(script.Parent.utils.ActiveQueue)

type Queued = { queuedAt: number, request: SharedTypes.CommandRequest, bytes: number, ticket: Admission.Ticket }

type Connection = {
	diagnostics: SharedTypes.DiagnosticCollector?,
	player: Player,
	node: Queue.Node<Connection>?,
	lastId: number,
	window: number,
	count: number,
	bytes: number,
	queue: { Queued },
	queuedBytes: number,
	history: History.Runtime,
}

type Limits = {
	requests: number,
	bytes: number,
	window: number,
	queued: number,
	queuedBytes: number,
	history: number,
	historyBytes: number,
	lifetime: number,
	globalRequests: number,
	globalBytes: number,
	globalQueued: number,
	globalQueuedBytes: number,
	dispatchRequests: number,
	dispatchVisits: number,
}

local ServerCommandRuntime = {}
ServerCommandRuntime.__index = ServerCommandRuntime

type State = {
	diagnostics: SharedTypes.DiagnosticCollector?,
	execution: Execution.Runtime,
	protocol: SharedTypes.ClientProtocol,
	codec: SharedTypes.CommandCodec,
	dependencies: Types.ServerCommandDependencies,
	limits: Limits,
	connections: { [Player]: Connection },
	destroyed: boolean,
	disconnect: (() -> ())?,
	disconnectReady: (() -> ())?,
	admission: Admission.Runtime,
	active: Queue.Queue<Connection>,
	pumping: boolean,
	queued: number,
	queuedBytes: number,
}

type Runtime = typeof(setmetatable({} :: State, ServerCommandRuntime))

-- Only connection eligibility is linked here. Jobs retain exactly one owner:
-- their existing per-connection FIFO, then the dispatch stack while executing.
function ServerCommandRuntime._activate(self: Runtime, connection: Connection): ()
	local node = connection.node

	if node == nil then
		node = Queue.node(connection)
		connection.node = node
	end

	assert(node ~= nil, "Expected command connection node")
	Queue.Push(self.active, node)
end

function ServerCommandRuntime._deactivate(_self: Runtime, connection: Connection): ()
	if connection.node ~= nil then
		Queue.Remove(connection.node)
	end
end

function ServerCommandRuntime._close(self: Runtime, player: Player): ()
	self.admission:Closed(player)
	local connection: Connection? = self.connections[player]

	if connection == nil then
		return
	end

	self.connections[player] = nil
	self:_deactivate(connection)

	connection.history:Destroy()

	-- A popped invocation remains charged until its dispatch stack returns,
	-- even if author code closes/reopens the connection or destroys the runtime.
	Metrics.Count(connection.diagnostics, "commandsAbandoned", #connection.queue)
	self.queued -= #connection.queue
	Metrics.Adjust(connection.diagnostics, "commandRequests", -#connection.queue)
	Metrics.Adjust(connection.diagnostics, "commandBytes", -connection.queuedBytes)
	self.queuedBytes -= connection.queuedBytes

	for _, queued in connection.queue do
		self.admission:Release(queued.ticket)
	end

	table.clear(connection.queue)

	if connection.diagnostics ~= nil then
		connection.diagnostics:SetAgeSource("commandQueueAgeSeconds", nil)
	end

	connection.queuedBytes = 0
end

function ServerCommandRuntime.Handle(self: Runtime, player: Player, payload: any, ...: any): (boolean, string?)
	if self.destroyed then
		return false, "ClientNotReady"
	end

	Metrics.Count(Diagnostics.FindConnection(player) or self.diagnostics, "commandsReceived", 1)

	if not self.dependencies.IsClientReady(player) then
		Metrics.Count(Diagnostics.FindConnection(player) or self.diagnostics, "commandsRefused", 1)

		return false, "ClientNotReady"
	end

	local now: number = self.dependencies.Now()
	local existing: Connection? = self.connections[player]

	if existing == nil then
		local created: Connection = {
			diagnostics = Diagnostics.GetConnection(player),
			player = player,
			lastId = 0,
			window = now,
			count = 0,
			bytes = 0,
			queue = {},
			queuedBytes = 0,
			history = History.new(
				Diagnostics.GetConnection(player),
				self.dependencies.Now,
				self.dependencies.ScheduleTimeout,
				self.limits.history,
				self.limits.historyBytes,
				self.limits.lifetime
			),
		}

		existing = created
		self.connections[player] = created

		if created.diagnostics ~= nil then
			created.diagnostics:SetAgeSource("commandQueueAgeSeconds", function(): number?
				local head = created.queue[1]

				return if head ~= nil then math.max(0, self.dependencies.Now() - head.queuedAt) else nil
			end)
		end
	end

	local connection: Connection = existing :: Connection

	if now - connection.window >= self.limits.window then
		connection.window = now
		connection.count = 0
		connection.bytes = 0
	end

	local size: number = if typeof(payload) == "buffer" then buffer.len(payload) else 0

	if connection.count >= self.limits.requests or size > self.limits.bytes - connection.bytes then
		Metrics.Count(Diagnostics.FindConnection(player) or self.diagnostics, "commandsRefused", 1)

		Metrics.Count(connection.diagnostics, "commandsRateLimited", 1)
		Metrics.Warn(connection.diagnostics, "CommandOverload", "CommandRateLimited")

		return false, "CommandRateLimited"
	end

	connection.count += 1
	connection.bytes += size

	-- Charge attempted ingress before decoding, including malformed and refused
	-- requests. Draining or disconnecting must not reset the aggregate rate gate.
	if not self.admission:Attempt(player, size, now) then
		Metrics.Count(Diagnostics.FindConnection(player) or self.diagnostics, "commandsRefused", 1)

		Metrics.Count(connection.diagnostics, "commandsRateLimited", 1)
		Metrics.Warn(connection.diagnostics, "CommandOverload", "CommandGlobalRateLimited")

		return false, "CommandGlobalRateLimited"
	end

	if select("#", ...) ~= 0 then
		Metrics.Warn(connection.diagnostics, "MalformedTraffic", "MalformedCommandEnvelope")
		Metrics.Count(Diagnostics.FindConnection(player) or self.diagnostics, "commandsRefused", 1)

		return false, "MalformedCommandEnvelope"
	end

	local request: SharedTypes.CommandRequest?, reason: string? = self.codec.DecodeRequest(payload)

	if request == nil then
		Metrics.Warn(connection.diagnostics, "MalformedTraffic", reason)
		Metrics.Count(Diagnostics.FindConnection(player) or self.diagnostics, "commandsRefused", 1)

		return false, reason
	end

	if request.requestId <= connection.lastId then
		Metrics.Warn(connection.diagnostics, "CommandOverload", "ReplayedRequestId")
		Metrics.Count(Diagnostics.FindConnection(player) or self.diagnostics, "commandsRefused", 1)

		return false, "ReplayedRequestId"
	end

	connection.lastId = request.requestId

	if #connection.queue >= self.limits.queued or size > self.limits.queuedBytes - connection.queuedBytes then
		Metrics.Warn(connection.diagnostics, "CommandOverload", "CommandQueueFull")
		Metrics.Count(Diagnostics.FindConnection(player) or self.diagnostics, "commandsRefused", 1)

		return false, "CommandQueueFull"
	end

	local ticket = self.admission:Queue(player, size, self.queued, self.queuedBytes)

	if ticket == nil then
		Metrics.Warn(connection.diagnostics, "CommandOverload", "CommandGlobalQueueFull")
		Metrics.Count(Diagnostics.FindConnection(player) or self.diagnostics, "commandsRefused", 1)

		return false, "CommandGlobalQueueFull"
	end

	table.insert(connection.queue, { queuedAt = now, request = request, bytes = size, ticket = ticket })
	connection.queuedBytes += size
	self.queued += 1
	Metrics.Count(connection.diagnostics, "commandsAdmitted", 1)
	Metrics.Adjust(connection.diagnostics, "commandRequests", 1)
	Metrics.Adjust(connection.diagnostics, "commandBytes", size)
	self.queuedBytes += size
	self:_activate(connection)

	return true, nil
end

function ServerCommandRuntime.Step(self: Runtime): (number, number)
	if self.destroyed or self.pumping then
		return 0, 0
	end

	self.pumping = true
	self.admission:Advance(self.dependencies.Now())
	local dispatched, visits, unproductive = 0, 0, 0

	while
		self.active.count > 0
		and not self.destroyed
		and dispatched < self.limits.dispatchRequests
		and visits < self.limits.dispatchVisits
	do
		local connection = Queue.Pop(self.active)
		assert(connection ~= nil, "Expected active command connection")
		local player = connection.player

		-- Rotate membership before callbacks, preserving the admitted FIFO owner
		-- and the next connection's turn through reentrant enqueue/close.
		self:_activate(connection)
		visits += 1
		Metrics.Count(connection.diagnostics, "commandConnectionVisits", 1)
		local running: Queued? = nil
		local observation: CommandDiagnostics.Observation? = nil
		local reservation: Types.CommandReservation? = nil

		local completed = pcall(function()
			if not self.dependencies.IsClientReady(player) then
				self:_close(player)

				return
			end

			local queued = connection.queue[1]
			local commands = self.protocol.commandsByCode :: { [number]: SharedTypes.ClientCommand }
			local command = commands[queued.request.commandCode]

			local maximum = math.max(
				9 + Constants.MAX_REASON_BYTES,
				8 + (if command.resultCodec ~= nil then command.resultCodec.maxSizeBytes else 0)
			)

			reservation = self.dependencies.awareness:ReserveCommandResult(player, maximum)

			if reservation == nil then
				return -- Keep the FIFO head and all admission charges; no effects.
			end

			if self.destroyed or self.connections[player] ~= connection then
				(reservation :: Types.CommandReservation).Cancel()

				return
			end

			running = table.remove(connection.queue, 1) :: Queued
			connection.queuedBytes -= queued.bytes
			dispatched += 1
			Metrics.Count(connection.diagnostics, "commandsDispatched", 1)

			Metrics.Observe(
				connection.diagnostics,
				"commandQueueResidenceSeconds",
				math.max(0, self.dependencies.Now() - queued.queuedAt)
			)

			local observed = CommandDiagnostics.new(connection.diagnostics)
			observation = observed

			self.execution:Execute(player, connection.history, connection.diagnostics, function(): boolean
				return not self.destroyed and self.connections[player] == connection
			end, queued.request, reservation :: Types.CommandReservation, observed)
		end)

		if not completed then
			if reservation ~= nil then
				pcall((reservation :: Types.CommandReservation).Cancel)
			end

			if observation ~= nil then
				CommandDiagnostics.Fault(observation)
				CommandDiagnostics.Uncertain(observation)
			else
				Metrics.Count(connection.diagnostics, "commandsFaulted", 1)
			end

			pcall(self.dependencies.ReportFault, player, "CommandInternalFault")
			pcall(self.dependencies.CloseConnection, player, "CommandInternalFault")
			self:_close(player)
		end

		if running ~= nil then
			self.queued -= 1
			Metrics.Adjust(connection.diagnostics, "commandRequests", -1)
			Metrics.Adjust(connection.diagnostics, "commandBytes", -(running :: Queued).bytes)
			self.queuedBytes -= (running :: Queued).bytes
			self.admission:Release((running :: Queued).ticket)
			unproductive = 0
		else
			unproductive += 1
			Metrics.Count(connection.diagnostics, "commandUnproductiveInspections", 1)
		end

		if #connection.queue == 0 then
			self:_deactivate(connection)
		end

		if unproductive >= self.active.count then
			break
		end
	end

	self.pumping = false
	Metrics.Observe(self.diagnostics, "commandPumpWorkUnits", visits + dispatched)

	return dispatched, visits
end

function ServerCommandRuntime._GetPendingForTests(self: Runtime): (number, number)
	return self.queued, self.queuedBytes
end

function ServerCommandRuntime.Destroy(self: Runtime): ()
	if self.destroyed then
		return
	end

	self.destroyed = true

	if self.disconnectReady ~= nil then
		pcall(self.disconnectReady)
		self.disconnectReady = nil
	end

	if self.disconnect ~= nil then
		pcall(self.disconnect)
		self.disconnect = nil
	end

	for player: Player in self.connections do
		self:_close(player)
	end

	self.admission:Destroy()
end

function ServerCommandRuntime.new(
	catalog: Types.PreparedCommandCatalog,
	protocol: SharedTypes.ClientProtocol,
	dependencies: Types.ServerCommandDependencies,
	options: Types.ServerCommandLimits?
): Types.ServerCommandRuntime
	local limits: Types.ServerCommandLimits = options or {}
	local maximumRequest = 11

	for _, command in protocol.commandsByCode or {} do
		maximumRequest = math.max(
			maximumRequest,
			11 + (if command.requestCodec ~= nil then command.requestCodec.maxSizeBytes else 0)
		)
	end

	local codec = Codec.Compile(protocol)

	local state: State = {
		diagnostics = Diagnostics.GetServer(),
		execution = Execution.new(catalog, protocol, codec, dependencies),
		protocol = protocol,
		codec = codec,
		dependencies = dependencies,
		limits = {
			requests = limits.maxRequests or Constants.MAX_REQUESTS,
			bytes = limits.maxBytes or Constants.MAX_BYTES,
			window = limits.windowSeconds or Constants.WINDOW_SECONDS,
			queued = limits.maxQueuedRequests or Constants.MAX_QUEUED_REQUESTS,
			queuedBytes = limits.maxQueuedBytes or Constants.MAX_QUEUED_BYTES,
			history = limits.maxHistory or Constants.MAX_HISTORY,
			historyBytes = limits.maxHistoryBytes or Constants.MAX_HISTORY_BYTES,
			lifetime = limits.historySeconds or Constants.HISTORY_SECONDS,
			globalRequests = limits.maxGlobalRequests or Constants.MAX_GLOBAL_REQUESTS,
			globalBytes = limits.maxGlobalBytes or Constants.MAX_GLOBAL_BYTES,
			globalQueued = limits.maxGlobalQueuedRequests or Constants.MAX_GLOBAL_QUEUED_REQUESTS,
			globalQueuedBytes = limits.maxGlobalQueuedBytes or Constants.MAX_GLOBAL_QUEUED_BYTES,
			dispatchRequests = limits.maxDispatchRequests or Constants.DISPATCH_REQUESTS,
			dispatchVisits = limits.maxDispatchVisits or Constants.DISPATCH_VISITS,
		},
		connections = {},
		destroyed = false,
		active = Queue.new(),
		pumping = false,
		queued = 0,
		queuedBytes = 0,
		admission = Admission.new(
			limits.maxGlobalRequests or Constants.MAX_GLOBAL_REQUESTS,
			limits.maxGlobalBytes or Constants.MAX_GLOBAL_BYTES,
			limits.maxGlobalQueuedRequests or Constants.MAX_GLOBAL_QUEUED_REQUESTS,
			limits.maxGlobalQueuedBytes or Constants.MAX_GLOBAL_QUEUED_BYTES,
			maximumRequest,
			limits.windowSeconds or Constants.WINDOW_SECONDS,
			dependencies.Now()
		),
	}

	for _, limit: number in
		{
			state.limits.requests,
			state.limits.bytes,
			state.limits.window,
			state.limits.queued,
			state.limits.queuedBytes,
			state.limits.history,
			state.limits.historyBytes,
			state.limits.lifetime,
			state.limits.globalRequests,
			state.limits.globalBytes,
			state.limits.globalQueued,
			state.limits.globalQueuedBytes,
			state.limits.dispatchRequests,
			state.limits.dispatchVisits,
		}
	do
		assert(limit >= 0 and limit < math.huge, "InvalidCommandLimit")
	end

	local self: Runtime = setmetatable(state, ServerCommandRuntime)

	for _, limit: number in
		{
			state.limits.globalRequests,
			state.limits.globalBytes,
			state.limits.globalQueued,
			state.limits.globalQueuedBytes,
			state.limits.dispatchRequests,
			state.limits.dispatchVisits,
		}
	do
		assert(limit % 1 == 0, "InvalidCommandLimit")
	end

	self.disconnect = dependencies.ObserveClientClosed(function(player: Player): ()
		self:_close(player)
	end)

	self.disconnectReady = dependencies.ObserveClientReady(function(player: Player): ()
		if not self.destroyed and dependencies.IsClientReady(player) then
			self.admission:Ready(player)
		end
	end)

	return self :: Types.ServerCommandRuntime
end

return ServerCommandRuntime
