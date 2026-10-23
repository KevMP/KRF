--!strict
local Types = require(script.Parent.types)
local ActorTypes = require(script.Parent.Parent.Actor.types)
local SharedTypes = require(script.Parent.Parent.Parent.shared.Networking.types)
local Constants = require(script.Parent.Parent.Parent.shared.Networking.utils.CommandConstants)
local Codec = require(script.Parent.Parent.Parent.shared.Networking.CommandCodec)
local Timer = require(script.Parent.Parent.Parent.shared.Networking.utils.CommandTimer)
local Context = require(script.Parent.utils.CommandContext)

type History = { outcome: Types.CommandOutcome, bytes: number, expires: number }
type Queued = { request: SharedTypes.CommandRequest, bytes: number }

type Connection = {
	lastId: number,
	window: number,
	count: number,
	bytes: number,
	queue: { Queued },
	queuedBytes: number,
	draining: boolean,
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
}

local ServerCommandRuntime = {}
ServerCommandRuntime.__index = ServerCommandRuntime

type State = {
	catalog: Types.PreparedCommandCatalog,
	protocol: SharedTypes.ClientProtocol,
	codec: SharedTypes.CommandCodec,
	dependencies: Types.ServerCommandDependencies,
	limits: Limits,
	connections: { [Player]: Connection },
	destroyed: boolean,
	disconnect: (() -> ())?,
}

type Runtime = typeof(setmetatable({} :: State, ServerCommandRuntime))

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
	local connection: Connection? = self.connections[player]

	if connection == nil then
		return
	end

	self.connections[player] = nil

	if connection.cancelExpiry ~= nil then
		connection.cancelExpiry()
		connection.cancelExpiry = nil
	end

	table.clear(connection.queue)
	table.clear(connection.history)
	table.clear(connection.order)
	connection.queuedBytes = 0
	connection.historyBytes = 0
end

function ServerCommandRuntime._execute(
	self: Runtime,
	player: Player,
	connection: Connection,
	request: SharedTypes.CommandRequest
): ()
	local commands: { [number]: SharedTypes.ClientCommand } = self.protocol.commandsByCode or {}
	local command: SharedTypes.ClientCommand = commands[request.commandCode]
	local definition: Types.LoadedCommandDefinition = self.catalog.definitionsById[command.id]

	local maximum: number = math.max(
		9 + Constants.MAX_REASON_BYTES,
		8 + (if command.resultCodec ~= nil then command.resultCodec.maxSizeBytes else 0)
	)

	local reservation: Types.CommandReservation? = self.dependencies.awareness:ReserveCommandResult(player, maximum)

	if reservation == nil then
		return
	end

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

	if self.connections[player] ~= connection or self.destroyed or not self.dependencies.IsClientReady(player) then
		reservation.Cancel()

		return
	end

	local encoded: buffer? = nil

	if fault == nil then
		encoded = self.codec.EncodeResult(outcome)

		if encoded == nil then
			fault = "CommandResultFault"
		end
	end

	if fault ~= nil then
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
	end

	self:_armExpiry(player, connection)

	if not reservation.Commit(encoded) then
		self.dependencies.CloseConnection(player, "CommandEgressFault")
	end
end

function ServerCommandRuntime.Handle(self: Runtime, player: Player, payload: any, ...: any): (boolean, string?)
	if self.destroyed or not self.dependencies.IsClientReady(player) then
		return false, "ClientNotReady"
	end

	local now: number = self.dependencies.Now()
	local existing: Connection? = self.connections[player]

	if existing == nil then
		local created: Connection = {
			lastId = 0,
			window = now,
			count = 0,
			bytes = 0,
			queue = {},
			queuedBytes = 0,
			draining = false,
			history = {},
			order = {},
			historyBytes = 0,
		}

		existing = created
		self.connections[player] = created
	end

	local connection: Connection = existing :: Connection

	if now - connection.window >= self.limits.window then
		connection.window = now
		connection.count = 0
		connection.bytes = 0
	end

	local size: number = if typeof(payload) == "buffer" then buffer.len(payload) else 0

	if connection.count >= self.limits.requests or size > self.limits.bytes - connection.bytes then
		return false, "CommandRateLimited"
	end

	connection.count += 1
	connection.bytes += size

	if select("#", ...) ~= 0 then
		return false, "MalformedCommandEnvelope"
	end

	local request: SharedTypes.CommandRequest?, reason: string? = self.codec.DecodeRequest(payload)

	if request == nil then
		return false, reason
	end

	if request.requestId <= connection.lastId then
		return false, "ReplayedRequestId"
	end

	connection.lastId = request.requestId

	if #connection.queue >= self.limits.queued or size > self.limits.queuedBytes - connection.queuedBytes then
		return false, "CommandQueueFull"
	end

	table.insert(connection.queue, { request = request, bytes = size })
	connection.queuedBytes += size

	if connection.draining then
		return true, nil
	end

	connection.draining = true

	while self.connections[player] == connection and #connection.queue > 0 and not self.destroyed do
		local queued: Queued = table.remove(connection.queue, 1) :: Queued

		connection.queuedBytes -= queued.bytes

		local completed: boolean = pcall(self._execute, self, player, connection, queued.request)

		if not completed then
			pcall(self.dependencies.ReportFault, player, "CommandInternalFault")
			pcall(self.dependencies.CloseConnection, player, "CommandInternalFault")
			self:_close(player)
		end
	end

	connection.draining = false

	return true, nil
end

function ServerCommandRuntime.Destroy(self: Runtime): ()
	if self.destroyed then
		return
	end

	self.destroyed = true

	if self.disconnect ~= nil then
		self.disconnect()
		self.disconnect = nil
	end

	for player: Player in self.connections do
		self:_close(player)
	end
end

function ServerCommandRuntime.new(
	catalog: Types.PreparedCommandCatalog,
	protocol: SharedTypes.ClientProtocol,
	dependencies: Types.ServerCommandDependencies,
	options: Types.ServerCommandLimits?
): Types.ServerCommandRuntime
	local limits: Types.ServerCommandLimits = options or {}

	local state: State = {
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
		},
		connections = {},
		destroyed = false,
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
		}
	do
		assert(limit >= 0 and limit < math.huge, "InvalidCommandLimit")
	end

	local self: Runtime = setmetatable(state, ServerCommandRuntime)

	self.disconnect = dependencies.ObserveClientClosed(function(player: Player): ()
		self:_close(player)
	end)

	return self :: Types.ServerCommandRuntime
end

return ServerCommandRuntime
