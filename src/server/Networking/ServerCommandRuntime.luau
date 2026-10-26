--!strict
local Types = require(script.Parent.types)
local ActorTypes = require(script.Parent.Parent.Actor.types)
local SharedTypes = require(script.Parent.Parent.Parent.shared.Networking.types)
local Metrics = require(script.Parent.Parent.Parent.shared.Networking.utils.NetworkingMetrics)
local Diagnostics = require(script.Parent.utils.NetworkingDiagnosticsState)
local Constants = require(script.Parent.Parent.Parent.shared.Networking.utils.CommandConstants)
local Codec = require(script.Parent.Parent.Parent.shared.Networking.CommandCodec)
local Timer = require(script.Parent.Parent.Parent.shared.Networking.utils.CommandTimer)
local Context = require(script.Parent.utils.CommandContext)
local CommandDiagnostics = require(script.Parent.utils.CommandDiagnostics)
local Admission = require(script.Parent.utils.CommandAdmission)

type History = { outcome: Types.CommandOutcome, bytes: number, expires: number }
type Queued = { queuedAt: number, request: SharedTypes.CommandRequest, bytes: number, ticket: Admission.Ticket }

type Connection = {
	diagnostics: SharedTypes.DiagnosticCollector?,
	player: Player,
	next: Connection?,
	previous: Connection?,
	lastId: number,
	window: number,
	count: number,
	bytes: number,
	queue: { Queued },
	queuedBytes: number,
	history: { [number]: History },
	order: { number },
	historyBytes: number,
	cancelExpiry: (() -> ())?,
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
	catalog: Types.PreparedCommandCatalog,
	protocol: SharedTypes.ClientProtocol,
	codec: SharedTypes.CommandCodec,
	dependencies: Types.ServerCommandDependencies,
	limits: Limits,
	connections: { [Player]: Connection },
	destroyed: boolean,
	disconnect: (() -> ())?,
	disconnectReady: (() -> ())?,
	admission: Admission.Runtime,
	active: Connection?,
	activeCount: number,
	pumping: boolean,
	queued: number,
	queuedBytes: number,
}

type Runtime = typeof(setmetatable({} :: State, ServerCommandRuntime))

-- Only connection eligibility is linked here. Jobs retain exactly one owner:
-- their existing per-connection FIFO, then the dispatch stack while executing.
function ServerCommandRuntime._activate(self: Runtime, connection: Connection): ()
	if connection.next ~= nil then
		return
	end

	local active = self.active

	if active == nil then
		connection.next, connection.previous = connection, connection
		self.active = connection
	else
		local tail = active.previous :: Connection

		connection.next, connection.previous = active, tail
		tail.next, active.previous = connection, connection
	end

	self.activeCount += 1
end

function ServerCommandRuntime._deactivate(self: Runtime, connection: Connection): ()
	local following = connection.next

	if following == nil then
		return
	end

	if following == connection then
		self.active = nil
	else
		local previous = connection.previous :: Connection
		previous.next, following.previous = following, previous

		if self.active == connection then
			self.active = following
		end
	end

	connection.next, connection.previous = nil, nil
	self.activeCount -= 1
end

local function invoke(callback: (...any) -> ...any, ...: any): (boolean, any, any)
	local callbackThread: thread = coroutine.create(callback)
	local completed: boolean, first: any, second: any = coroutine.resume(callbackThread, ...)

	if coroutine.status(callbackThread) ~= "dead" then
		pcall(task.cancel, callbackThread)
		pcall(coroutine.close, callbackThread)

		return false, "CommandCallbackYielded", nil
	end

	return completed, first, second
end

local function reasonValid(reason: any): boolean
	return type(reason) == "string" and #reason > 0 and #reason <= Constants.MAX_REASON_BYTES
end

local function evict(connection: Connection): ()
	local id: number = table.remove(connection.order, 1) :: number
	local previous: History = connection.history[id]

	connection.historyBytes -= previous.bytes
	Metrics.Adjust(connection.diagnostics, "commandHistoryEntries", -1)
	Metrics.Adjust(connection.diagnostics, "commandHistoryBytes", -previous.bytes)
	connection.history[id] = nil
end

function ServerCommandRuntime._expire(self: Runtime, connection: Connection): ()
	while #connection.order > 0 and connection.history[connection.order[1]].expires <= self.dependencies.Now() do
		evict(connection)
	end
end

function ServerCommandRuntime._armExpiry(self: Runtime, player: Player, connection: Connection): ()
	if connection.cancelExpiry ~= nil then
		connection.cancelExpiry()
		connection.cancelExpiry = nil
	end

	local id: number? = connection.order[1]

	if id == nil or self.connections[player] ~= connection then
		return
	end

	local schedule: (number, () -> ()) -> () -> () = self.dependencies.ScheduleTimeout or Timer.Schedule

	connection.cancelExpiry = schedule(
		math.max(0, connection.history[id].expires - self.dependencies.Now()),
		function(): ()
			connection.cancelExpiry = nil

			if self.connections[player] == connection then
				self:_expire(connection)
				self:_armExpiry(player, connection)
			end
		end
	)
end

function ServerCommandRuntime._close(self: Runtime, player: Player): ()
	self.admission:Closed(player)
	local connection: Connection? = self.connections[player]

	if connection == nil then
		return
	end

	self.connections[player] = nil
	self:_deactivate(connection)

	if connection.cancelExpiry ~= nil then
		pcall(connection.cancelExpiry)
		connection.cancelExpiry = nil
	end

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
	Metrics.Set(connection.diagnostics, "commandHistoryEntries", 0)
	Metrics.Set(connection.diagnostics, "commandHistoryBytes", 0)

	if connection.diagnostics ~= nil then
		connection.diagnostics:SetAgeSource("commandQueueAgeSeconds", nil)
	end

	table.clear(connection.history)
	table.clear(connection.order)
	connection.queuedBytes = 0
	connection.historyBytes = 0
end

function ServerCommandRuntime._execute(
	self: Runtime,
	player: Player,
	connection: Connection,
	request: SharedTypes.CommandRequest,
	reservation: Types.CommandReservation,
	observation: CommandDiagnostics.Observation
): ()
	local commands: { [number]: SharedTypes.ClientCommand } = self.protocol.commandsByCode or {}
	local command: SharedTypes.ClientCommand = commands[request.commandCode]
	local definition: Types.LoadedCommandDefinition = self.catalog.definitionsById[command.id]

	local actor: ActorTypes.Actor? = nil
	local targetReason: string? = nil

	if request.targetHandle ~= nil then
		actor, targetReason = self.dependencies.awareness:ResolveActor(player, request.targetHandle)
	end

	local outcome: SharedTypes.CommandResult = {
		commandCode = request.commandCode,
		requestId = request.requestId,
		status = "Rejected",
		reason = "ActorUnavailable",
	}

	local fault: string? = nil

	if request.targetHandle == nil or actor ~= nil then
		local context: Types.CommandContext, closeContext: () -> () = Context.new(
			player,
			actor,
			request.requestId,
			command.id,
			function(id: number): Types.CommandOutcome?
				if
					self.connections[player] ~= connection
					or type(id) ~= "number"
					or id <= 0
					or id >= request.requestId
					or id % 1 ~= 0
				then
					return nil
				end

				self:_expire(connection)
				local prior: History? = connection.history[id]

				return if prior ~= nil then prior.outcome else nil
			end,
			{
				ready = function(): boolean
					return self.connections[player] == connection and self.dependencies.IsClientReady(player)
				end,
				owns = function(): boolean
					return actor ~= nil
						and self.dependencies.awareness:GetPlayerForActor(actor) == player
						and self.dependencies.awareness:GetActorForPlayer(player) == actor
				end,
			}
		)

		local authorized: boolean, allowed: any, denial: any = invoke(definition.authorize, context, request.request)

		if
			not authorized
			or type(allowed) ~= "boolean"
			or (allowed == false and not reasonValid(denial))
			or (allowed == true and denial ~= nil)
		then
			fault = "CommandAuthorizationFault"
		elseif not allowed then
			outcome =
				{ commandCode = command.code, requestId = request.requestId, status = "Rejected", reason = denial }
		elseif self.connections[player] == connection then
			Metrics.Count(connection.diagnostics, "commandsExecuted", 1)
			local handled: boolean, result: any = invoke(definition.handle, context, request.request)

			if not handled or type(result) ~= "table" or type(rawget(result, "accepted")) ~= "boolean" then
				fault = "CommandHandlerFault"
			else
				for key in next, result do
					if key ~= "accepted" and key ~= "result" and key ~= "reason" then
						fault = "CommandHandlerFault"
					end
				end

				outcome = {
					commandCode = command.code,
					requestId = request.requestId,
					status = if result.accepted then "Accepted" else "Rejected",
					result = rawget(result, "result"),
					reason = rawget(result, "reason") :: any,
				}
			end
		end

		closeContext()
	elseif targetReason ~= nil then
		-- Safely correlated valid envelopes may receive a bounded pre-effect rejection.
		outcome = {
			commandCode = command.code,
			requestId = request.requestId,
			status = "Rejected",
			reason = "ActorUnavailable",
		}
	end

	if fault ~= nil then
		CommandDiagnostics.Fault(observation)
	end

	if self.connections[player] ~= connection or self.destroyed or not self.dependencies.IsClientReady(player) then
		CommandDiagnostics.Uncertain(observation)
		reservation.Cancel()

		return
	end

	local encoded: buffer? = nil

	if fault == nil then
		encoded = self.codec.EncodeResult(outcome)

		if encoded == nil then
			fault = "CommandResultFault"
			CommandDiagnostics.Fault(observation)
		end
	end

	if fault ~= nil then
		CommandDiagnostics.Uncertain(observation)
		outcome = { commandCode = command.code, requestId = request.requestId, status = "Unknown", reason = fault }
		encoded = self.codec.EncodeResult(outcome)
		pcall(self.dependencies.ReportFault, player, fault)
	end

	if self.connections[player] ~= connection or self.destroyed then
		reservation.Cancel()

		return
	end

	if encoded == nil then
		reservation.Cancel()
		self.dependencies.CloseConnection(player, "CommandEgressFault")

		return
	end

	-- Round-trip through the compiled result schema before retaining any author data.
	local owned: SharedTypes.CommandResult? = self.codec.DecodeResult(encoded)
	assert(owned ~= nil, "Encoded command result must decode")

	if owned.status ~= "Unknown" then
		Metrics.Count(
			connection.diagnostics,
			if owned.status == "Accepted" then "commandsAccepted" else "commandsRejected",
			1
		)
	end

	local retained: Types.CommandOutcome = table.freeze({
		requestId = request.requestId,
		commandId = command.id,
		targetActor = actor,
		status = owned.status,
		result = owned.result,
		reason = owned.reason,
	})

	self:_expire(connection)
	local historyBytes: number = buffer.len(encoded) + #command.id + 24

	while
		#connection.order > 0
		and (
			#connection.order >= self.limits.history
			or connection.historyBytes + historyBytes > self.limits.historyBytes
		)
	do
		evict(connection)
	end

	if self.limits.history > 0 and historyBytes <= self.limits.historyBytes then
		connection.history[request.requestId] =
			{ outcome = retained, bytes = historyBytes, expires = self.dependencies.Now() + self.limits.lifetime }

		table.insert(connection.order, request.requestId)
		connection.historyBytes += historyBytes
		Metrics.Adjust(connection.diagnostics, "commandHistoryEntries", 1)
		Metrics.Adjust(connection.diagnostics, "commandHistoryBytes", historyBytes)
	end

	self:_armExpiry(player, connection)

	if not reservation.Commit(encoded) then
		CommandDiagnostics.Fault(observation)
		CommandDiagnostics.Uncertain(observation)
		self.dependencies.CloseConnection(player, "CommandEgressFault")
	end
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
			history = {},
			order = {},
			historyBytes = 0,
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

		return false, "CommandRateLimited"
	end

	connection.count += 1
	connection.bytes += size

	-- Charge attempted ingress before decoding, including malformed and refused
	-- requests. Draining or disconnecting must not reset the aggregate rate gate.
	if not self.admission:Attempt(player, size, now) then
		Metrics.Count(Diagnostics.FindConnection(player) or self.diagnostics, "commandsRefused", 1)

		Metrics.Count(connection.diagnostics, "commandsRateLimited", 1)

		return false, "CommandGlobalRateLimited"
	end

	if select("#", ...) ~= 0 then
		Metrics.Count(Diagnostics.FindConnection(player) or self.diagnostics, "commandsRefused", 1)

		return false, "MalformedCommandEnvelope"
	end

	local request: SharedTypes.CommandRequest?, reason: string? = self.codec.DecodeRequest(payload)

	if request == nil then
		Metrics.Count(Diagnostics.FindConnection(player) or self.diagnostics, "commandsRefused", 1)

		return false, reason
	end

	if request.requestId <= connection.lastId then
		Metrics.Count(Diagnostics.FindConnection(player) or self.diagnostics, "commandsRefused", 1)

		return false, "ReplayedRequestId"
	end

	connection.lastId = request.requestId

	if #connection.queue >= self.limits.queued or size > self.limits.queuedBytes - connection.queuedBytes then
		Metrics.Count(Diagnostics.FindConnection(player) or self.diagnostics, "commandsRefused", 1)

		return false, "CommandQueueFull"
	end

	local ticket = self.admission:Queue(player, size, self.queued, self.queuedBytes)

	if ticket == nil then
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
		self.active ~= nil
		and not self.destroyed
		and dispatched < self.limits.dispatchRequests
		and visits < self.limits.dispatchVisits
	do
		local connection = self.active :: Connection
		local player = connection.player

		self.active = connection.next
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
			self:_execute(player, connection, queued.request, reservation :: Types.CommandReservation, observed)
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

		if unproductive >= self.activeCount then
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

	local state: State = {
		diagnostics = Diagnostics.GetServer(),
		catalog = catalog,
		protocol = protocol,
		codec = Codec.Compile(protocol),
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
		activeCount = 0,
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
