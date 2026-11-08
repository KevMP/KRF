--!strict
local Types = require(script.Parent.types)
local PublicTypes = require(script.Parent.Parent.Actor.types)
local SharedTypes = require(script.Parent.Parent.Parent.shared.Networking.types)
local Metrics = require(script.Parent.Parent.Parent.shared.Networking.utils.NetworkingMetrics)
local Diagnostics = require(script.Parent.utils.NetworkingDiagnosticsState)
local Constants = require(script.Parent.Parent.Parent.shared.Networking.utils.CommandConstants)
local Codec = require(script.Parent.Parent.Parent.shared.Networking.CommandCodec)
local Registry = require(script.Parent.Parent.Actor.utils.ActorViewRegistryState)
local Events = require(script.Parent.utils.CommandRuntimeState)
local Observers = require(script.Parent.Parent.Parent.shared.Signal.PrivateObservers)

type Pending = {
	command: SharedTypes.ClientCommand,
	actor: PublicTypes.ActorView?,
	bytes: number,
	uncertain: boolean,
	cancel: (() -> ())?,
}

-- One physical reliable send. Reserved slots hold their place while an admission
-- callback runs, so no reentrant send can overtake a lower request ID.
type Egress = { id: number, payload: buffer, reserved: boolean }

type Prepared = { command: SharedTypes.ClientCommand, id: number, payload: buffer, bytes: number }

type State = {
	diagnostics: SharedTypes.DiagnosticCollector?,
	protocol: SharedTypes.ClientProtocol,
	codec: SharedTypes.CommandCodec,
	stream: Types.ActorStreamRuntime,
	options: Types.ClientCommandOptions,
	nextId: number,
	pending: { [number]: Pending },
	count: number,
	bytes: number,
	destroyed: boolean,
	egress: { Egress },
	flushing: boolean,
	observers: { (Types.CommandResult) -> () },
	-- Framework-classified lifecycle follow-ups and the pending headroom kept for them.
	followUps: { [string]: boolean },
	followUpPending: number,
	followUpBytes: number,
}

local ClientCommandRuntime = {}
ClientCommandRuntime.__index = ClientCommandRuntime

type Runtime = typeof(setmetatable({} :: State, ClientCommandRuntime))

function ClientCommandRuntime._remove(self: Runtime, id: number): Pending?
	local pending: Pending? = self.pending[id]

	if pending == nil then
		return nil
	end

	self.pending[id] = nil
	self.count -= 1
	self.bytes -= pending.bytes
	Metrics.Adjust(self.diagnostics, "clientCommandPending", -1)
	Metrics.Adjust(self.diagnostics, "clientCommandMetadataBytes", -pending.bytes)

	if pending.cancel ~= nil then
		pending.cancel()
		pending.cancel = nil
	end

	return pending
end

function ClientCommandRuntime._notify(
	self: Runtime,
	id: number,
	pending: Pending,
	status: "Accepted" | "Rejected" | "Unknown",
	result: any,
	reason: string?
): ()
	Metrics.Count(
		self.diagnostics,
		if status == "Unknown"
			then "commandsUncertain"
			else if status == "Accepted" then "commandsAccepted" else "commandsRejected",
		1
	)

	local message: Types.CommandResult = table.freeze({
		requestId = id,
		commandId = pending.command.id,
		targetActorView = pending.actor,
		status = status,
		result = result,
		reason = reason,
	})

	-- Framework owners correlate synchronously before any yield-safe public delivery.
	-- A throwing or yielding observer is contained and never suspends egress.
	for _, observer: (Types.CommandResult) -> () in table.clone(self.observers) do
		if table.find(self.observers, observer) ~= nil then
			Observers.Run(observer, message)
		end
	end

	Events.Notify(message)
end

function ClientCommandRuntime._uncertain(self: Runtime, id: number, reason: string): ()
	local pending: Pending? = self.pending[id]

	if pending == nil or pending.uncertain then
		return
	end

	pending.uncertain = true

	if pending.cancel ~= nil then
		pending.cancel()
		pending.cancel = nil
	end

	pending.cancel = self.options.ScheduleTimeout(self.options.graceSeconds or Constants.GRACE_SECONDS, function(): ()
		pending.cancel = nil
		self:_remove(id)
	end)

	self:_notify(id, pending, "Unknown", nil, reason)
end

function ClientCommandRuntime._prepare(
	self: Runtime,
	commandId: string,
	actor: PublicTypes.ActorView?,
	request: any?
): (Prepared?, string?)
	if self.destroyed or not self.options.IsReady() then
		return nil, "ClientNotReady"
	end

	local commands: { [string]: SharedTypes.ClientCommand } = self.protocol.commandsById or {}
	local command: SharedTypes.ClientCommand? = commands[commandId]

	if command == nil then
		return nil, "UnknownCommand"
	end

	local handle: number? = nil

	if command.target == "Actor" then
		if actor == nil or not Registry.IsCurrent(actor) or not actor:IsAvailable() then
			return nil, "ActorViewUnavailable"
		end

		local record: Types.ActorStreamRecord? = self.stream:GetByActorId(actor:GetId())

		if record == nil or self.stream:GetByHandle(record.handle) ~= record then
			return nil, "ActorViewUnavailable"
		end

		handle = record.handle
	elseif actor ~= nil then
		return nil, "UnexpectedActorTarget"
	end

	if self.nextId > (self.options.maxRequestId or Constants.MAX_COUNTER) then
		return nil, "RequestIdExhausted"
	end

	local id: number = self.nextId

	local payload: buffer?, reason: string? = self.codec.EncodeRequest({
		commandCode = command.code,
		requestId = id,
		targetHandle = handle,
		request = request,
	})

	if payload == nil then
		return nil, reason
	end

	-- Retain only correlation metadata and the live view, never the original request.
	local bytes: number = 32 + #command.id
	local followUp: boolean = self.followUps[command.id] == true
	local maxPending: number = self.options.maxPending or Constants.MAX_PENDING
	local maxPendingBytes: number = self.options.maxPendingBytes or Constants.MAX_PENDING_BYTES

	-- Ordinary commands leave the follow-up headroom free; follow-ups may use the
	-- whole bound and never exceed it.
	if not followUp then
		maxPending -= self.followUpPending
		maxPendingBytes -= self.followUpBytes
	end

	if self.count >= maxPending or self.bytes + bytes > maxPendingBytes then
		return nil, "CommandPendingFull"
	end

	return { command = command, id = id, payload = payload, bytes = bytes }, nil
end

function ClientCommandRuntime._track(self: Runtime, prepared: Prepared, actor: PublicTypes.ActorView?): ()
	local id: number = prepared.id
	local pending: Pending = { command = prepared.command, actor = actor, bytes = prepared.bytes, uncertain = false }

	self.pending[id] = pending
	self.count += 1
	self.bytes += prepared.bytes
	Metrics.Count(self.diagnostics, "commandsAdmitted", 1)
	Metrics.Adjust(self.diagnostics, "clientCommandPending", 1)
	Metrics.Adjust(self.diagnostics, "clientCommandMetadataBytes", prepared.bytes)

	pending.cancel = self.options.ScheduleTimeout(
		self.options.timeoutSeconds or Constants.TIMEOUT_SECONDS,
		function(): ()
			pending.cancel = nil
			self:_uncertain(id, "CommandTimeout")
		end
	)
end

-- Sends ready packets in request-ID order. A reentrant caller only enqueues; the
-- outermost flush drains, and a reserved head blocks every later packet.
function ClientCommandRuntime._flush(self: Runtime): ()
	if self.flushing then
		return
	end

	self.flushing = true

	while not self.destroyed do
		local head: Egress? = self.egress[1]

		if head == nil or head.reserved then
			break
		end

		table.remove(self.egress, 1)

		-- The transport must complete on this stack. A yield is cancelled and reported
		-- uncertain, since the packet may already have left, so the queue stays live.
		local sent: boolean, failure: string? = Observers.Run(self.options.SendReliable, head.payload)

		if not sent then
			Metrics.Count(self.diagnostics, "commandsFaulted", 1)

			self:_uncertain(
				head.id,
				if failure == "Yielded" then "CommandTransportYielded" else "CommandTransportFault"
			)
		end
	end

	self.flushing = false
end

function ClientCommandRuntime.Send(
	self: Runtime,
	commandId: string,
	actor: PublicTypes.ActorView?,
	request: any?
): (number?, string?)
	local prepared: Prepared?, reason: string? = self:_prepare(commandId, actor, request)

	if prepared == nil then
		Metrics.Count(self.diagnostics, "commandsRefused", 1)

		return nil, reason
	end

	self.nextId += 1
	self:_track(prepared, actor)
	table.insert(self.egress, { id = prepared.id, payload = prepared.payload, reserved = false })
	self:_flush()

	return prepared.id, nil
end

function ClientCommandRuntime._SendAdmitted(
	self: Runtime,
	commandId: string,
	actor: PublicTypes.ActorView?,
	request: any?,
	admit: Types.CommandAdmission
): (number?, string?)
	local prepared: Prepared?, reason: string? = self:_prepare(commandId, actor, request)

	if prepared == nil then
		Metrics.Count(self.diagnostics, "commandsRefused", 1)

		return nil, reason
	end

	local id: number = prepared.id
	local slot: Egress = { id = id, payload = prepared.payload, reserved = true }

	self.nextId += 1
	table.insert(self.egress, slot)

	local completed: boolean, admitted: any = pcall(admit, id)

	if not completed or admitted ~= true or self.destroyed then
		local index: number? = table.find(self.egress, slot)

		if index ~= nil then
			table.remove(self.egress, index)
		end

		-- Return the ID only when no reentrant send allocated past it.
		if self.nextId == id + 1 then
			self.nextId = id
		end

		Metrics.Count(self.diagnostics, "commandsRefused", 1)
		self:_flush()

		return nil,
			if self.destroyed
				then "ClientNotReady"
				elseif completed then "CommandAdmissionRefused"
				else "CommandAdmissionFailed"
	end

	self:_track(prepared, actor)
	slot.reserved = false
	self:_flush()

	return id, nil
end

function ClientCommandRuntime._ObserveOutcomes(self: Runtime, observer: (Types.CommandResult) -> ()): () -> ()
	table.insert(self.observers, observer)

	return function(): ()
		local index: number? = table.find(self.observers, observer)

		if index ~= nil then
			table.remove(self.observers, index)
		end
	end
end

-- Lets a framework owner classify its lifecycle follow-ups. They share every pending
-- bound, but ordinary commands cannot consume the bounded headroom kept for them.
function ClientCommandRuntime._ClassifyFollowUps(self: Runtime, commandIds: { string }): (boolean, string?)
	local commands: { [string]: SharedTypes.ClientCommand } = self.protocol.commandsById or {}
	local largest: number = 0

	for _, commandId: string in commandIds do
		if commands[commandId] == nil then
			return false, "UnknownCommand"
		end

		largest = math.max(largest, 32 + #commandId)
	end

	local maxPending: number = self.options.maxPending or Constants.MAX_PENDING
	local maxPendingBytes: number = self.options.maxPendingBytes or Constants.MAX_PENDING_BYTES

	table.clear(self.followUps)

	for _, commandId: string in commandIds do
		self.followUps[commandId] = true
	end

	if #commandIds == 0 then
		self.followUpPending, self.followUpBytes = 0, 0
	else
		-- At most half of each bound, so ordinary commands are never starved either.
		self.followUpPending = math.min(
			math.floor(maxPending / 2),
			math.max(1, math.floor(maxPending / Constants.FOLLOW_UP_RESERVE_DIVISOR))
		)

		self.followUpBytes = math.min(
			math.floor(maxPendingBytes / 2),
			math.max(largest, math.floor(maxPendingBytes / Constants.FOLLOW_UP_RESERVE_DIVISOR))
		)
	end

	return true, nil
end

function ClientCommandRuntime.Handle(self: Runtime, payload: any): boolean
	if self.destroyed or not self.options.IsReady() then
		return false
	end

	local result: SharedTypes.CommandResult? = self.codec.DecodeResult(payload)

	if result == nil then
		return false
	end

	local pending: Pending? = self.pending[result.requestId]

	if pending == nil or pending.command.code ~= result.commandCode then
		return false
	end

	Metrics.Count(self.diagnostics, "commandResultsReceived", 1)

	if result.status == "Unknown" then
		self:_uncertain(result.requestId, result.reason :: string)
	else
		self:_remove(result.requestId)
		self:_notify(result.requestId, pending, result.status, result.result, result.reason)
	end

	return true
end

function ClientCommandRuntime.Destroy(self: Runtime): ()
	if self.destroyed then
		return
	end

	self.destroyed = true
	table.clear(self.egress)

	for id: number, pending: Pending in self.pending do
		self:_remove(id)

		if not pending.uncertain then
			self:_notify(id, pending, "Unknown", nil, "CommandConnectionClosed")
		end
	end
end

function ClientCommandRuntime.new(
	protocol: SharedTypes.ClientProtocol,
	stream: Types.ActorStreamRuntime,
	options: Types.ClientCommandOptions
): Types.ClientCommandRuntime
	local state: State = {
		diagnostics = Diagnostics.Get(),
		protocol = protocol,
		codec = Codec.Compile(protocol),
		stream = stream,
		options = options,
		nextId = 1,
		pending = {},
		count = 0,
		bytes = 0,
		destroyed = false,
		egress = {},
		flushing = false,
		observers = {},
		followUps = {},
		followUpPending = 0,
		followUpBytes = 0,
	}

	return setmetatable(state, ClientCommandRuntime) :: Types.ClientCommandRuntime
end

return ClientCommandRuntime
