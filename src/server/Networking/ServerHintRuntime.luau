--!strict
local Types = require(script.Parent.types)
local ActorTypes = require(script.Parent.Parent.Actor.types)
local SharedTypes = require(script.Parent.Parent.Parent.shared.Networking.types)
local Metrics = require(script.Parent.Parent.Parent.shared.Networking.utils.NetworkingMetrics)
local Diagnostics = require(script.Parent.utils.NetworkingDiagnosticsState)
local Constants = require(script.Parent.Parent.Parent.shared.Networking.utils.HintConstants)
local Codec = require(script.Parent.Parent.Parent.shared.Networking.HintCodec)
local Queue = require(script.Parent.utils.ActiveQueue)
local Dispatch = require(script.Parent.utils.HintDispatcher)

type Packet = { queuedAt: number, cursor: SharedTypes.HintCursor, bytes: number, held: boolean }

type Limits = {
	maxPackets: number,
	maxBytes: number,
	maxGlobalPackets: number,
	maxGlobalBytes: number,
	maxPendingPackets: number,
	maxPendingBytes: number,
	maxGlobalPendingPackets: number,
	maxGlobalPendingBytes: number,
	maxRecords: number,
	maxLatestKeys: number,
	maxGlobalLatestKeys: number,
	windowSeconds: number,
}

type Connection = {
	diagnostics: SharedTypes.DiagnosticCollector?,
	player: Player,
	node: Queue.Node<Connection>?,
	packets: { Packet },
	bytes: number,
	window: number,
	attempts: number,
	rateBytes: number,
	delivery: Dispatch.Channel,
}

local ServerHintRuntime = {}
ServerHintRuntime.__index = ServerHintRuntime

type State = {
	diagnostics: SharedTypes.DiagnosticCollector?,
	dispatch: Dispatch.Runtime,
	codec: SharedTypes.HintCodec,
	dependencies: Types.ServerHintDependencies,
	limits: Limits,
	connections: { [Player]: Connection },
	active: Queue.Queue<Connection>,
	pendingCount: number,
	pendingBytes: number,
	window: number,
	attempts: number,
	rateBytes: number,
	destroyed: boolean,
	pumping: boolean,
	staged: Packet?,
	disconnects: { () -> () },
}

type Runtime = typeof(setmetatable({} :: State, ServerHintRuntime))

function ServerHintRuntime._current(self: Runtime, connection: Connection): boolean
	return not self.destroyed
		and self.connections[connection.player] == connection
		and self.dependencies.IsClientReady(connection.player)
end

function ServerHintRuntime._release(self: Runtime, connection: Connection, packet: Packet): ()
	if not packet.held then
		return
	end

	packet.held = false

	if packet.cursor.remaining > 0 then
		Metrics.Count(connection.diagnostics, "hintPacketsDropped", 1)
		Metrics.Count(connection.diagnostics, "hintsDropped", packet.cursor.remaining)
	end

	self.pendingCount -= 1
	Metrics.Adjust(connection.diagnostics, "hintReceivePackets", -1)
	self.pendingBytes -= packet.bytes
	Metrics.Adjust(connection.diagnostics, "hintReceiveBytes", -packet.bytes)
	connection.bytes -= packet.bytes
end

function ServerHintRuntime._close(self: Runtime, player: Player): ()
	local connection = self.connections[player]

	if connection == nil then
		return
	end

	self.connections[player] = nil

	if connection.node ~= nil then
		Queue.Remove(connection.node)
	end

	for _, packet in connection.packets do
		if packet ~= self.staged then
			self:_release(connection, packet)
		end
	end

	self.dispatch:Close(connection.delivery)

	if connection.diagnostics ~= nil then
		connection.diagnostics:SetAgeSource("hintReceiveQueueAgeSeconds", nil)
	end

	connection.packets = {}
end

function ServerHintRuntime.ForgetActor(self: Runtime, actor: ActorTypes.Actor): ()
	-- Only retirement traverses live sequence keys, never ingress or idle pumps.
	for _, connection in self.connections do
		self.dispatch:ForgetActor(connection.delivery, actor)
	end
end

function ServerHintRuntime.Handle(self: Runtime, player: Player, payload: any, ...: any): (boolean, string?)
	local connection = self.connections[player]

	local diagnosticOwner = if self.destroyed
		then nil
		else if connection ~= nil
			then connection.diagnostics
			else Diagnostics.FindConnection(player) or self.diagnostics

	if connection == nil or not self:_current(connection) then
		Metrics.Count(diagnosticOwner, "hintPacketsRefused", 1)
		Metrics.Count(diagnosticOwner, "hintPacketsDropped", 1)

		return false, "ClientNotReady"
	end

	local now = self.dependencies.Now()

	if now - connection.window >= self.limits.windowSeconds then
		connection.window, connection.attempts, connection.rateBytes = now, 0, 0
	end

	if now - self.window >= self.limits.windowSeconds then
		self.window, self.attempts, self.rateBytes = now, 0, 0
	end

	if connection.attempts >= self.limits.maxPackets or self.attempts >= self.limits.maxGlobalPackets then
		Metrics.Count(diagnosticOwner, "hintPacketsRefused", 1)
		Metrics.Count(diagnosticOwner, "hintPacketsDropped", 1)

		Metrics.Warn(diagnosticOwner, "HintAbuse", "HintRateLimited")

		return false, "HintRateLimited"
	end

	connection.attempts += 1
	self.attempts += 1

	if select("#", ...) ~= 0 then
		Metrics.Count(diagnosticOwner, "hintPacketsRefused", 1)
		Metrics.Count(diagnosticOwner, "hintPacketsDropped", 1)

		Metrics.Count(diagnosticOwner, "hintsMalformed", 1)
		Metrics.Warn(diagnosticOwner, "MalformedTraffic", "hintsMalformed")

		return false, "MalformedHintPacket"
	end

	local cursor, reason = self.codec.Open(payload)

	if cursor == nil then
		Metrics.Count(diagnosticOwner, "hintsMalformed", 1)
		Metrics.Warn(diagnosticOwner, "MalformedTraffic", "hintsMalformed")
		Metrics.Count(diagnosticOwner, "hintPacketsRefused", 1)
		Metrics.Count(diagnosticOwner, "hintPacketsDropped", 1)

		return false, reason
	end

	local bytes = buffer.len(cursor.source)

	if connection.rateBytes + bytes > self.limits.maxBytes or self.rateBytes + bytes > self.limits.maxGlobalBytes then
		Metrics.Count(diagnosticOwner, "hintPacketsRefused", 1)
		Metrics.Count(diagnosticOwner, "hintPacketsDropped", 1)

		Metrics.Warn(diagnosticOwner, "HintAbuse", "HintRateLimited")

		return false, "HintRateLimited"
	end

	connection.rateBytes += bytes
	self.rateBytes += bytes

	if
		#connection.packets >= self.limits.maxPendingPackets
		or connection.bytes + bytes > self.limits.maxPendingBytes
		or self.pendingCount >= self.limits.maxGlobalPendingPackets
		or self.pendingBytes + bytes > self.limits.maxGlobalPendingBytes
	then
		Metrics.Count(diagnosticOwner, "hintPacketsRefused", 1)
		Metrics.Count(diagnosticOwner, "hintPacketsDropped", 1)

		Metrics.Warn(diagnosticOwner, "HintAbuse", "HintPendingFull")

		return false, "HintPendingFull"
	end

	-- Incoming data has exactly one queue owner. Never decode in Handle.
	local owned = buffer.create(bytes)
	buffer.copy(owned, 0, cursor.source)
	cursor.source = owned
	table.insert(connection.packets, { queuedAt = now, cursor = cursor, bytes = bytes, held = true })
	connection.bytes += bytes
	self.pendingCount += 1
	Metrics.Adjust(connection.diagnostics, "hintReceivePackets", 1)
	self.pendingBytes += bytes
	Metrics.Adjust(connection.diagnostics, "hintReceiveBytes", bytes)

	local node = connection.node
	assert(node ~= nil, "Expected Hint connection node")
	Queue.Push(self.active, node)

	Metrics.Count(connection.diagnostics, "hintPacketsAdmitted", 1)

	return true, nil
end

function ServerHintRuntime.Step(self: Runtime): (number, number)
	if self.destroyed or self.pumping then
		return 0, 0
	end

	self.pumping = true
	local work, delivered = 0, 0

	while not self.destroyed and work < self.limits.maxRecords do
		local connection = Queue.Pop(self.active)

		if connection == nil then
			break
		end

		work += 1
		Metrics.Count(connection.diagnostics, "hintReceiveVisits", 1)
		Metrics.Count(connection.diagnostics, "hintConnectionVisits", 1)
		local packet = connection.packets[1]
		assert(packet ~= nil, "Expected active Hint packet")
		self.staged = packet

		Metrics.Observe(
			connection.diagnostics,
			"hintReceiveQueueResidenceSeconds",
			math.max(0, self.dependencies.Now() - packet.queuedAt)
		)

		local completed, record = pcall(self.codec.Read, packet.cursor)

		if completed and record ~= nil and self.dispatch:Deliver(connection.delivery, record) then
			delivered += 1
		else
			Metrics.Count(connection.diagnostics, "hintUnproductiveInspections", 1)
		end

		if not completed or record == nil then
			Metrics.Count(connection.diagnostics, "hintsMalformed", 1)
			Metrics.Warn(connection.diagnostics, "MalformedTraffic", "hintsMalformed")
		end

		if not completed or record == nil or packet.cursor.remaining == 0 or not self:_current(connection) then
			if connection.packets[1] == packet then
				table.remove(connection.packets, 1)
			end

			self:_release(connection, packet)
		end

		self.staged = nil

		if self:_current(connection) and #connection.packets > 0 then
			local node = connection.node
			assert(node ~= nil, "Expected Hint connection node")
			Queue.Push(self.active, node)
		end
	end

	self.pumping = false
	Metrics.Observe(self.diagnostics, "hintReceivePumpWorkUnits", work)

	return work, delivered
end

function ServerHintRuntime.Destroy(self: Runtime): ()
	if self.destroyed then
		return
	end

	self.destroyed = true

	for _, disconnect in self.disconnects do
		disconnect()
	end

	table.clear(self.disconnects)

	for player in self.connections do
		self:_close(player)
	end
end

function ServerHintRuntime.new(
	catalog: Types.PreparedHintCatalog,
	protocol: SharedTypes.ClientProtocol,
	dependencies: Types.ServerHintDependencies,
	overrides: Types.ServerHintLimits?
): Types.ServerHintRuntime
	local options: Types.ServerHintLimits = overrides or {}

	local limits: Limits = {
		maxPackets = options.maxPackets or Constants.SERVER_PACKETS,
		maxBytes = options.maxBytes or Constants.SERVER_BYTES,
		maxGlobalPackets = options.maxGlobalPackets or Constants.GLOBAL_PACKETS,
		maxGlobalBytes = options.maxGlobalBytes or Constants.GLOBAL_BYTES,
		maxPendingPackets = options.maxPendingPackets or Constants.PENDING_PACKETS,
		maxPendingBytes = options.maxPendingBytes or Constants.PENDING_PACKET_BYTES,
		maxGlobalPendingPackets = options.maxGlobalPendingPackets or Constants.GLOBAL_PENDING_PACKETS,
		maxGlobalPendingBytes = options.maxGlobalPendingBytes or Constants.GLOBAL_PENDING_BYTES,
		maxRecords = options.maxRecords or Constants.STEP_RECORDS,
		maxLatestKeys = options.maxLatestKeys or Constants.LATEST_KEYS,
		maxGlobalLatestKeys = options.maxGlobalLatestKeys or Constants.GLOBAL_LATEST_KEYS,
		windowSeconds = options.windowSeconds or Constants.WINDOW_SECONDS,
	}

	for _, value in
		{
			limits.maxPackets,
			limits.maxBytes,
			limits.maxGlobalPackets,
			limits.maxGlobalBytes,
			limits.maxPendingPackets,
			limits.maxPendingBytes,
			limits.maxGlobalPendingPackets,
			limits.maxGlobalPendingBytes,
			limits.maxRecords,
			limits.maxLatestKeys,
			limits.maxGlobalLatestKeys,
			limits.windowSeconds,
		}
	do
		assert(value > 0 and value < math.huge, "InvalidHintLimits")
	end

	local state: State = {
		diagnostics = Diagnostics.GetServer(),
		dispatch = Dispatch.new(catalog, protocol, dependencies.awareness, limits),
		codec = Codec.Compile(protocol),
		dependencies = dependencies,
		limits = limits,
		connections = {},
		active = Queue.new(),
		pendingCount = 0,
		pendingBytes = 0,
		window = dependencies.Now(),
		attempts = 0,
		rateBytes = 0,
		destroyed = false,
		pumping = false,
		disconnects = {},
	}

	local self: Runtime = setmetatable(state, ServerHintRuntime)

	table.insert(
		self.disconnects,
		dependencies.ObserveClientReady(function(player: Player): ()
			self:_close(player)

			if self.destroyed or not dependencies.IsClientReady(player) then
				return
			end

			local channel: Dispatch.Channel? = nil

			local created = self.dispatch:Open(player, Diagnostics.GetConnection(player), function(): boolean
				local connection = self.connections[player]

				return connection ~= nil and connection.delivery == channel and self:_current(connection)
			end)

			channel = created

			local connection: Connection = {
				diagnostics = Diagnostics.GetConnection(player),
				player = player,
				packets = {},
				bytes = 0,
				window = dependencies.Now(),
				attempts = 0,
				rateBytes = 0,
				delivery = created,
			}

			connection.node = Queue.node(connection)
			self.connections[player] = connection

			if connection.diagnostics ~= nil then
				connection.diagnostics:SetAgeSource("hintReceiveQueueAgeSeconds", function(): number?
					local head = connection.packets[1]

					return if head ~= nil and head.cursor.remaining > 0
						then math.max(0, dependencies.Now() - head.queuedAt)
						else nil
				end)
			end
		end)
	)

	table.insert(
		self.disconnects,
		dependencies.ObserveClientClosed(function(player: Player): ()
			self:_close(player)
		end)
	)

	if dependencies.ObserveActorRemoved ~= nil then
		table.insert(
			self.disconnects,
			dependencies.ObserveActorRemoved(function(actor: ActorTypes.Actor): ()
				self:ForgetActor(actor)
			end)
		)
	end

	return self :: Types.ServerHintRuntime
end

return ServerHintRuntime
