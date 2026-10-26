--!strict
local Types = require(script.Parent.Parent.types)
local PublicTypes = require(script.Parent.Parent.Parent.Actor.types)
local SharedTypes = require(script.Parent.Parent.Parent.Parent.shared.Networking.types)
local Metrics = require(script.Parent.Parent.Parent.Parent.shared.Networking.utils.NetworkingMetrics)
local Diagnostics = require(script.Parent.NetworkingDiagnosticsState)
local Constants = require(script.Parent.Parent.Parent.Parent.shared.Networking.utils.HintConstants)
local Codec = require(script.Parent.Parent.Parent.Parent.shared.Networking.HintCodec)
local Registry = require(script.Parent.Parent.Parent.Actor.utils.ActorViewRegistryState)

type Packet = { queuedAt: number, cursor: SharedTypes.HintCursor, bytes: number, held: boolean }
type Latest = { sequence: number, actor: PublicTypes.ActorView? }

local HintReceiver = {}
HintReceiver.__index = HintReceiver

type State = {
	diagnostics: SharedTypes.DiagnosticCollector?,
	protocol: SharedTypes.ClientProtocol,
	codec: SharedTypes.HintCodec,
	stream: Types.ActorStreamRuntime,
	dependencies: Types.HintReceiveDependencies,
	limits: Types.HintReceiveLimits,
	packets: { Packet },
	latest: { [string]: Latest },
	latestCount: number,
	pendingCount: number,
	pendingBytes: number,
	window: number,
	attempts: number,
	rateBytes: number,
	destroyed: boolean,
	pumping: boolean,
	staged: Packet?,
}

export type Runtime = typeof(setmetatable({} :: State, HintReceiver))

function HintReceiver._release(self: Runtime, packet: Packet): ()
	if not packet.held then
		return
	end

	packet.held = false

	if packet.cursor.remaining > 0 then
		Metrics.Count(self.diagnostics, "hintPacketsDropped", 1)
		Metrics.Count(self.diagnostics, "hintsDropped", packet.cursor.remaining)
	end

	self.pendingCount -= 1
	Metrics.Adjust(self.diagnostics, "hintReceivePackets", -1)
	self.pendingBytes -= packet.bytes
	Metrics.Adjust(self.diagnostics, "hintReceiveBytes", -packet.bytes)
end

function HintReceiver.Handle(self: Runtime, payload: any, ...: any): (boolean, string?)
	if self.destroyed or not self.dependencies.IsReady() then
		Metrics.Count(self.diagnostics, "hintPacketsRefused", 1)
		Metrics.Count(self.diagnostics, "hintPacketsDropped", 1)

		return false, "ClientNotReady"
	end

	local now = self.dependencies.Now()

	if now - self.window >= self.limits.windowSeconds then
		self.window, self.attempts, self.rateBytes = now, 0, 0
	end

	if self.attempts >= self.limits.maxPackets then
		Metrics.Count(self.diagnostics, "hintPacketsRefused", 1)
		Metrics.Count(self.diagnostics, "hintPacketsDropped", 1)

		return false, "HintRateLimited"
	end

	self.attempts += 1

	if select("#", ...) ~= 0 then
		Metrics.Count(self.diagnostics, "hintPacketsRefused", 1)
		Metrics.Count(self.diagnostics, "hintPacketsDropped", 1)

		Metrics.Count(self.diagnostics, "hintsMalformed", 1)

		return false, "MalformedHintPacket"
	end

	local cursor, reason = self.codec.Open(payload)

	if cursor == nil then
		Metrics.Count(self.diagnostics, "hintsMalformed", 1)
		Metrics.Count(self.diagnostics, "hintPacketsRefused", 1)
		Metrics.Count(self.diagnostics, "hintPacketsDropped", 1)

		return false, reason
	end

	local bytes = buffer.len(cursor.source)

	if self.rateBytes + bytes > self.limits.maxBytes then
		Metrics.Count(self.diagnostics, "hintPacketsRefused", 1)
		Metrics.Count(self.diagnostics, "hintPacketsDropped", 1)

		return false, "HintRateLimited"
	end

	self.rateBytes += bytes

	if
		self.pendingCount >= self.limits.maxPendingPackets
		or self.pendingBytes + bytes > self.limits.maxPendingBytes
	then
		Metrics.Count(self.diagnostics, "hintPacketsRefused", 1)
		Metrics.Count(self.diagnostics, "hintPacketsDropped", 1)

		return false, "HintPendingFull"
	end

	local owned = buffer.create(bytes)
	buffer.copy(owned, 0, cursor.source)
	cursor.source = owned
	table.insert(self.packets, { queuedAt = now, cursor = cursor, bytes = bytes, held = true })
	self.pendingCount += 1
	Metrics.Adjust(self.diagnostics, "hintReceivePackets", 1)
	self.pendingBytes += bytes
	Metrics.Adjust(self.diagnostics, "hintReceiveBytes", bytes)

	Metrics.Count(self.diagnostics, "hintPacketsAdmitted", 1)

	return true, nil
end

function HintReceiver._deliver(self: Runtime, record: SharedTypes.HintRecord): boolean
	local actor: PublicTypes.ActorView? = nil

	if record.targetHandle ~= nil then
		local mapping = self.stream:GetByHandle(record.targetHandle)

		if mapping == nil then
			Metrics.Count(self.diagnostics, "hintsDropped", 1)

			return false
		end

		actor = Registry.GetActorViewById(mapping.actorId)

		if
			actor == nil
			or not Registry.IsCurrent(actor)
			or not actor:IsAvailable()
			or self.stream:GetByActorId(mapping.actorId) ~= mapping
		then
			Metrics.Count(self.diagnostics, "hintsDropped", 1)

			return false
		end
	end

	local key = tostring(record.hintCode) .. ":" .. tostring(record.targetHandle or 0)

	if record.sequence ~= nil then
		local previous = self.latest[key]

		if previous ~= nil and record.sequence <= previous.sequence then
			Metrics.Count(self.diagnostics, "hintsStaleDropped", 1)
			Metrics.Count(self.diagnostics, "hintsDropped", 1)

			return false
		end

		if previous == nil then
			if self.latestCount >= self.limits.maxLatestKeys then
				Metrics.Count(self.diagnostics, "hintsDropped", 1)

				return false
			end

			self.latestCount += 1
			Metrics.Adjust(self.diagnostics, "hintLatestKeys", 1)
		end

		self.latest[key] = { sequence = record.sequence, actor = actor }
	end

	local hint = if self.protocol.hintsByCode ~= nil then self.protocol.hintsByCode[record.hintCode] else nil
	assert(hint ~= nil, "Expected decoded S2C Hint")
	local value: Types.HintReceived = table.freeze({ hintId = hint.id, actorView = actor, payload = record.payload })
	Metrics.Count(self.diagnostics, "hintsReceived", 1)
	local notifier = coroutine.create(self.dependencies.Notify)
	local completed = coroutine.resume(notifier, value)

	if coroutine.status(notifier) ~= "dead" then
		coroutine.close(notifier)
		Metrics.Count(self.diagnostics, "hintCallbackFaults", 1)

		return false
	end

	if not completed then
		Metrics.Count(self.diagnostics, "hintCallbackFaults", 1)
	end

	return completed
end

function HintReceiver.Step(self: Runtime): (number, number)
	if self.destroyed or self.pumping or not self.dependencies.IsReady() then
		return 0, 0
	end

	self.pumping = true
	local work, delivered = 0, 0

	while not self.destroyed and self.dependencies.IsReady() and work < self.limits.maxRecords do
		local packet = self.packets[1]

		if packet == nil then
			break
		end

		work += 1
		Metrics.Count(self.diagnostics, "hintReceiveVisits", 1)
		self.staged = packet

		Metrics.Observe(
			self.diagnostics,
			"hintReceiveQueueResidenceSeconds",
			math.max(0, self.dependencies.Now() - packet.queuedAt)
		)

		local completed, record = pcall(self.codec.Read, packet.cursor)

		if completed and record ~= nil and self:_deliver(record) then
			delivered += 1
		else
			Metrics.Count(self.diagnostics, "hintUnproductiveInspections", 1)
		end

		if not completed or record == nil then
			Metrics.Count(self.diagnostics, "hintsMalformed", 1)
		end

		if not completed or record == nil or packet.cursor.remaining == 0 or self.destroyed then
			if self.packets[1] == packet then
				table.remove(self.packets, 1)
			end

			self:_release(packet)
		end

		self.staged = nil
	end

	self.pumping = false
	Metrics.Observe(self.diagnostics, "hintReceivePumpWorkUnits", work)

	return work, delivered
end

function HintReceiver.ForgetActor(self: Runtime, actor: PublicTypes.ActorView): ()
	for key, latest in self.latest do
		if latest.actor == actor then
			self.latest[key] = nil
			self.latestCount -= 1
			Metrics.Adjust(self.diagnostics, "hintLatestKeys", -1)
		end
	end
	-- Undecoded packet ownership stays bounded; retired handles fail resolution
	-- when those packets receive their scheduled turn. No decode in lifecycle hooks.
end

function HintReceiver.Destroy(self: Runtime): ()
	if self.destroyed then
		return
	end

	self.destroyed = true

	for _, packet in self.packets do
		if packet ~= self.staged then
			self:_release(packet)
		end
	end

	Metrics.Adjust(self.diagnostics, "hintLatestKeys", -self.latestCount)

	if self.diagnostics ~= nil then
		self.diagnostics:SetAgeSource("hintReceiveQueueAgeSeconds", nil)
	end

	self.packets, self.latest, self.latestCount = {}, {}, 0
end

function HintReceiver.new(
	protocol: SharedTypes.ClientProtocol,
	stream: Types.ActorStreamRuntime,
	dependencies: Types.HintReceiveDependencies,
	overrides: Types.HintReceiveLimits?
): Runtime
	local limits: Types.HintReceiveLimits = overrides or (table.clone(Constants.RECEIVE) :: Types.HintReceiveLimits)

	for _, value in
		{
			limits.windowSeconds,
			limits.maxPackets,
			limits.maxBytes,
			limits.maxPendingPackets,
			limits.maxPendingBytes,
			limits.maxRecords,
			limits.maxLatestKeys,
		}
	do
		assert(value > 0 and value < math.huge, "InvalidHintLimits")
	end

	local state: State = {
		diagnostics = Diagnostics.Get(),
		protocol = protocol,
		stream = stream,
		dependencies = dependencies,
		limits = limits,
		codec = Codec.Compile(protocol, "ServerToClient"),
		packets = {},
		latest = {},
		latestCount = 0,
		pendingCount = 0,
		pendingBytes = 0,
		window = dependencies.Now(),
		attempts = 0,
		rateBytes = 0,
		destroyed = false,
		pumping = false,
	}

	local self: Runtime = setmetatable(state, HintReceiver)

	if self.diagnostics ~= nil then
		self.diagnostics:SetAgeSource("hintReceiveQueueAgeSeconds", function(): number?
			local head = self.packets[1]

			return if head ~= nil and head.cursor.remaining > 0
				then math.max(0, dependencies.Now() - head.queuedAt)
				else nil
		end)
	end

	return self
end

return HintReceiver
