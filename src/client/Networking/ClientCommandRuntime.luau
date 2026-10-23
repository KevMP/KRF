--!strict
local Types = require(script.Parent.types)
local PublicTypes = require(script.Parent.Parent.Actor.types)
local SharedTypes = require(script.Parent.Parent.Parent.shared.Networking.types)
local Constants = require(script.Parent.Parent.Parent.shared.Networking.utils.CommandConstants)
local Codec = require(script.Parent.Parent.Parent.shared.Networking.CommandCodec)
local Registry = require(script.Parent.Parent.Actor.utils.ActorViewRegistryState)
local Events = require(script.Parent.utils.CommandRuntimeState)

type Pending = {
	command: SharedTypes.ClientCommand,
	actor: PublicTypes.ActorView?,
	bytes: number,
	uncertain: boolean,
	cancel: (() -> ())?,
}

type State = {
	protocol: SharedTypes.ClientProtocol,
	codec: SharedTypes.CommandCodec,
	stream: Types.ActorStreamRuntime,
	options: Types.ClientCommandOptions,
	nextId: number,
	pending: { [number]: Pending },
	count: number,
	bytes: number,
	destroyed: boolean,
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

	if pending.cancel ~= nil then
		pending.cancel()
		pending.cancel = nil
	end

	return pending
end

function ClientCommandRuntime._notify(
	_self: Runtime,
	id: number,
	pending: Pending,
	status: "Accepted" | "Rejected" | "Unknown",
	result: any,
	reason: string?
): ()
	local message: Types.CommandResult = table.freeze({
		requestId = id,
		commandId = pending.command.id,
		targetActorView = pending.actor,
		status = status,
		result = result,
		reason = reason,
	})

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

function ClientCommandRuntime.Send(
	self: Runtime,
	commandId: string,
	actor: PublicTypes.ActorView?,
	request: any?
): (number?, string?)
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

	if
		self.count >= (self.options.maxPending or Constants.MAX_PENDING)
		or self.bytes + bytes > (self.options.maxPendingBytes or Constants.MAX_PENDING_BYTES)
	then
		return nil, "CommandPendingFull"
	end

	self.nextId += 1

	local pending: Pending = { command = command, actor = actor, bytes = bytes, uncertain = false }

	self.pending[id] = pending
	self.count += 1
	self.bytes += bytes

	pending.cancel = self.options.ScheduleTimeout(
		self.options.timeoutSeconds or Constants.TIMEOUT_SECONDS,
		function(): ()
			pending.cancel = nil
			self:_uncertain(id, "CommandTimeout")
		end
	)

	local sent: boolean = pcall(self.options.SendReliable, payload)

	if not sent then
		self:_uncertain(id, "CommandTransportFault")
	end

	return id, nil
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
		protocol = protocol,
		codec = Codec.Compile(protocol),
		stream = stream,
		options = options,
		nextId = 1,
		pending = {},
		count = 0,
		bytes = 0,
		destroyed = false,
	}

	return setmetatable(state, ClientCommandRuntime) :: Types.ClientCommandRuntime
end

return ClientCommandRuntime
