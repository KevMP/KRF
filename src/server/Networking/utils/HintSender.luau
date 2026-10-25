--!strict
local Types = require(script.Parent.Parent.types)
local ActorTypes = require(script.Parent.Parent.Parent.Actor.types)
local SharedTypes = require(script.Parent.Parent.Parent.Parent.shared.Networking.types)
local Metrics = require(script.Parent.Parent.Parent.Parent.shared.Networking.utils.NetworkingMetrics)
local Diagnostics = require(script.Parent.NetworkingDiagnosticsState)
local Constants = require(script.Parent.Parent.Parent.Parent.shared.Networking.utils.HintConstants)
local Codec = require(script.Parent.Parent.Parent.Parent.shared.Networking.HintCodec)
local Queue = require(script.Parent.ActiveQueue)

type Latest = { sequence: number, actor: ActorTypes.Actor?, job: Job? }
type Job = { bytes: buffer, actor: ActorTypes.Actor?, handle: number?, latest: Latest? }

type Connection = {
	diagnostics: SharedTypes.DiagnosticCollector?,
	player: Player,
	node: Queue.Node<Connection>?,
	queue: { Job },
	latest: { [string]: Latest },
	pendingCount: number,
	pendingBytes: number,
	latestCount: number,
	window: number,
	attempts: number,
	rateBytes: number,
}

local HintSender = {}
HintSender.__index = HintSender

type State = {
	protocol: SharedTypes.ClientProtocol,
	codec: SharedTypes.HintCodec,
	dependencies: Types.HintSendDependencies,
	limits: Types.HintSendLimits,
	connections: { [Player]: Connection },
	active: Queue.Queue<Connection>,
	disconnects: { () -> () },
	pendingCount: number,
	pendingBytes: number,
	latestCount: number,
	window: number,
	attempts: number,
	rateBytes: number,
	destroyed: boolean,
	pumping: boolean,
}

export type Runtime = typeof(setmetatable({} :: State, HintSender))

function HintSender._current(self: Runtime, connection: Connection): boolean
	return not self.destroyed
		and self.connections[connection.player] == connection
		and self.dependencies.IsClientReady(connection.player)
end

function HintSender._eligible(self: Runtime, connection: Connection, job: Job): boolean
	return self:_current(connection)
		and (
			job.actor == nil
			or (
				self.dependencies.awareness:GetHandle(connection.player, job.actor) == job.handle
				and self.dependencies.awareness:ResolveActor(connection.player, job.handle :: number) == job.actor
			)
		)
end

function HintSender._release(self: Runtime, connection: Connection, job: Job): ()
	local bytes = buffer.len(job.bytes)

	connection.pendingCount -= 1
	connection.pendingBytes -= bytes
	self.pendingCount -= 1
	Metrics.Adjust(connection.diagnostics, "hintSendRecords", -1)
	self.pendingBytes -= bytes
	Metrics.Adjust(connection.diagnostics, "hintSendBytes", -bytes)
end

function HintSender._close(self: Runtime, player: Player): ()
	local connection = self.connections[player]

	if connection == nil then
		return
	end

	self.connections[player] = nil

	if connection.node ~= nil then
		Queue.Remove(connection.node)
	end

	for _, job in connection.queue do
		self:_release(connection, job)
	end

	self.latestCount -= connection.latestCount
	connection.queue, connection.latest, connection.latestCount = {}, {}, 0
end

function HintSender.ForgetActor(self: Runtime, actor: ActorTypes.Actor): ()
	-- A lifecycle traversal is bounded by retained jobs/keys, never repeated at idle.
	for _, connection in self.connections do
		for index = #connection.queue, 1, -1 do
			local job = connection.queue[index]

			if job.actor == actor then
				table.remove(connection.queue, index)
				self:_release(connection, job)
			end
		end

		for key, latest in connection.latest do
			if latest.actor == actor then
				connection.latest[key] = nil
				connection.latestCount -= 1
				self.latestCount -= 1
			end
		end

		if #connection.queue == 0 and connection.node ~= nil then
			Queue.Remove(connection.node)
		end
	end
end

function HintSender.SendTo(
	self: Runtime,
	player: Player,
	id: string,
	actor: ActorTypes.Actor?,
	payload: any?
): (boolean, string?)
	local connection = self.connections[player]
	local diagnosticOwner = if connection ~= nil then connection.diagnostics else nil

	if connection == nil or not self:_current(connection) then
		Metrics.Count(diagnosticOwner, "hintRecordsRefused", 1)

		return false, "ClientNotReady"
	end

	local limits, now = self.limits, self.dependencies.Now()

	if now - connection.window >= limits.windowSeconds then
		connection.window, connection.attempts, connection.rateBytes = now, 0, 0
	end

	if now - self.window >= limits.windowSeconds then
		self.window, self.attempts, self.rateBytes = now, 0, 0
	end

	if connection.attempts >= limits.maxAttempts or self.attempts >= limits.maxGlobalAttempts then
		Metrics.Count(diagnosticOwner, "hintRecordsRefused", 1)

		return false, "HintRateLimited"
	end

	connection.attempts += 1
	self.attempts += 1

	local hint = if self.protocol.hintsById ~= nil then self.protocol.hintsById[id] else nil

	if hint == nil then
		Metrics.Count(diagnosticOwner, "hintRecordsRefused", 1)

		return false, "UnknownHint"
	end

	if hint.direction ~= "ServerToClient" then
		Metrics.Count(diagnosticOwner, "hintRecordsRefused", 1)

		return false, "HintDirectionMismatch"
	end

	local handle: number? = nil

	if hint.target == "Actor" then
		if actor == nil then
			Metrics.Count(diagnosticOwner, "hintRecordsRefused", 1)

			return false, "ActorUnavailable"
		end

		handle = self.dependencies.awareness:GetHandle(player, actor)

		if handle == nil or self.dependencies.awareness:ResolveActor(player, handle) ~= actor then
			Metrics.Count(diagnosticOwner, "hintRecordsRefused", 1)

			return false, "ActorUnavailable"
		end
	elseif actor ~= nil then
		Metrics.Count(diagnosticOwner, "hintRecordsRefused", 1)

		return false, "UnexpectedActorTarget"
	end

	local key = tostring(hint.code) .. ":" .. tostring(handle or 0)
	local latest = if hint.mode == "Latest" then connection.latest[key] else nil

	if hint.mode == "Latest" then
		if
			latest == nil
			and (connection.latestCount >= limits.maxLatestKeys or self.latestCount >= limits.maxGlobalLatestKeys)
		then
			Metrics.Count(diagnosticOwner, "hintRecordsRefused", 1)

			return false, "HintLatestKeysFull"
		end

		if latest ~= nil and latest.sequence >= limits.maxSequence then
			Metrics.Count(diagnosticOwner, "hintRecordsRefused", 1)

			return false, "HintSequenceExhausted"
		end
	end

	local previous = if latest ~= nil then latest.job else nil

	if
		previous == nil
		and (connection.pendingCount >= limits.maxPending or self.pendingCount >= limits.maxGlobalPending)
	then
		Metrics.Count(diagnosticOwner, "hintRecordsRefused", 1)

		return false, "HintPendingFull"
	end

	local sequence = if hint.mode == "Latest" then (if latest ~= nil then latest.sequence + 1 else 1) else nil

	local encoded, reason =
		self.codec.EncodeRecord({ hintCode = hint.code, targetHandle = handle, sequence = sequence, payload = payload })

	if encoded == nil then
		Metrics.Count(diagnosticOwner, "hintRecordsRefused", 1)

		return false, reason
	end

	local bytes = buffer.len(encoded)

	if connection.rateBytes + bytes > limits.maxBytes or self.rateBytes + bytes > limits.maxGlobalBytes then
		Metrics.Count(diagnosticOwner, "hintRecordsRefused", 1)

		return false, "HintRateLimited"
	end

	local delta = bytes - (if previous ~= nil then buffer.len(previous.bytes) else 0)

	if
		connection.pendingBytes + delta > limits.maxPendingBytes
		or self.pendingBytes + delta > limits.maxGlobalPendingBytes
	then
		Metrics.Count(diagnosticOwner, "hintRecordsRefused", 1)

		return false, "HintPendingFull"
	end

	connection.rateBytes += bytes
	self.rateBytes += bytes

	if sequence ~= nil then
		if latest == nil then
			local created: Latest = { sequence = sequence, actor = actor }
			latest = created
			connection.latest[key] = created
			connection.latestCount += 1
			self.latestCount += 1
		else
			latest.sequence = sequence
		end
	end

	connection.pendingBytes += delta
	self.pendingBytes += delta
	Metrics.Adjust(connection.diagnostics, "hintSendBytes", delta)

	if previous ~= nil then
		previous.bytes = encoded
	else
		local job: Job = { bytes = encoded, actor = actor, handle = handle, latest = latest }
		table.insert(connection.queue, job)
		connection.pendingCount += 1
		self.pendingCount += 1
		Metrics.Adjust(connection.diagnostics, "hintSendRecords", 1)

		if latest ~= nil then
			latest.job = job
		end
	end

	local node = assert(connection.node, "Expected Hint recipient node")
	Queue.Push(self.active, node)

	Metrics.Count(connection.diagnostics, "hintRecordsAdmitted", 1)

	return true, nil
end

function HintSender.Step(self: Runtime): (number, number)
	if self.destroyed or self.pumping then
		return 0, 0
	end

	self.pumping = true
	local work, sends, sentBytes = 0, 0, 0
	local limits = self.limits

	while
		not self.destroyed
		and work < limits.maxRecords
		and sends < limits.maxSends
		and sentBytes < limits.maxStepBytes
	do
		local connection = Queue.Pop(self.active)

		if connection == nil then
			break
		end

		local selected: { Job } = {}
		local records: { buffer } = {}
		local bytes, visits = Constants.PACKET_HEADER_BYTES, 0

		while
			#connection.queue > 0
			and work < limits.maxRecords
			and visits < limits.maxConnectionRecords
			and #records < Constants.MAX_RECORDS
		do
			work += 1
			visits += 1
			local job = connection.queue[1]
			local eligible = self:_eligible(connection, job)

			if
				eligible
				and (
					bytes + buffer.len(job.bytes) > Constants.MAX_PACKET_BYTES
					or sentBytes + bytes + buffer.len(job.bytes) > limits.maxStepBytes
				)
			then
				break
			end

			table.remove(connection.queue, 1)

			if job.latest ~= nil then
				job.latest.job = nil
			end

			if eligible then
				table.insert(selected, job)
				table.insert(records, job.bytes)
				bytes += buffer.len(job.bytes)
			else
				self:_release(connection, job)
			end
		end

		if #selected > 0 then
			local packet = assert(self.codec.Pack(records))
			sends += 1
			sentBytes += buffer.len(packet)
			local sender = coroutine.create(self.dependencies.SendUnreliable)
			coroutine.resume(sender, connection.player, packet)

			if coroutine.status(sender) ~= "dead" then
				coroutine.close(sender)
			end

			-- Jobs were removed from the queue but remain charged through callback unwind.
			for _, job in selected do
				self:_release(connection, job)
			end
		end

		if self:_current(connection) and #connection.queue > 0 then
			Queue.Push(self.active, assert(connection.node, "Expected Hint recipient node"))
		end
	end

	self.pumping = false

	return work, sends
end

function HintSender.Destroy(self: Runtime): ()
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

function HintSender.new(
	protocol: SharedTypes.ClientProtocol,
	dependencies: Types.HintSendDependencies,
	overrides: Types.HintSendLimits?
): Runtime
	local limits: Types.HintSendLimits = overrides or (table.clone(Constants.SEND) :: Types.HintSendLimits)

	for _, value in
		{
			limits.windowSeconds,
			limits.maxAttempts,
			limits.maxBytes,
			limits.maxGlobalAttempts,
			limits.maxGlobalBytes,
			limits.maxPending,
			limits.maxPendingBytes,
			limits.maxGlobalPending,
			limits.maxGlobalPendingBytes,
			limits.maxLatestKeys,
			limits.maxGlobalLatestKeys,
			limits.maxSequence,
			limits.maxRecords,
			limits.maxConnectionRecords,
			limits.maxSends,
			limits.maxStepBytes,
		}
	do
		assert(value > 0 and value < math.huge, "InvalidHintLimits")
	end

	assert(
		limits.maxSequence <= Constants.MAX_COUNTER and limits.maxStepBytes >= Constants.MAX_PACKET_BYTES,
		"InvalidHintLimits"
	)

	local state: State = {
		protocol = protocol,
		codec = Codec.Compile(protocol, "ServerToClient"),
		dependencies = dependencies,
		limits = limits,
		connections = {},
		active = Queue.new(),
		disconnects = {},
		pendingCount = 0,
		pendingBytes = 0,
		latestCount = 0,
		window = dependencies.Now(),
		attempts = 0,
		rateBytes = 0,
		destroyed = false,
		pumping = false,
	}

	local self: Runtime = setmetatable(state, HintSender)

	table.insert(
		self.disconnects,
		dependencies.ObserveClientReady(function(player: Player): ()
			self:_close(player)

			if self.destroyed or not dependencies.IsClientReady(player) then
				return
			end

			local connection: Connection = {
				diagnostics = Diagnostics.GetConnection(player),
				player = player,
				queue = {},
				latest = {},
				pendingCount = 0,
				pendingBytes = 0,
				latestCount = 0,
				window = dependencies.Now(),
				attempts = 0,
				rateBytes = 0,
			}

			connection.node = Queue.node(connection)
			self.connections[player] = connection
		end)
	)

	table.insert(
		self.disconnects,
		dependencies.ObserveClientClosed(function(player: Player): ()
			self:_close(player)
		end)
	)

	table.insert(
		self.disconnects,
		dependencies.ObserveActorRemoved(function(actor: ActorTypes.Actor): ()
			self:ForgetActor(actor)
		end)
	)

	return self
end

return HintSender
