--!strict
local Types = require(script.Parent.types)
local PublicTypes = require(script.Parent.Parent.Actor.types)
local SharedTypes = require(script.Parent.Parent.Parent.shared.Networking.types)
local Metrics = require(script.Parent.Parent.Parent.shared.Networking.utils.NetworkingMetrics)
local Diagnostics = require(script.Parent.utils.NetworkingDiagnosticsState)
local Constants = require(script.Parent.Parent.Parent.shared.Networking.utils.HintConstants)
local Codec = require(script.Parent.Parent.Parent.shared.Networking.HintCodec)
local Outbox = require(script.Parent.Parent.Parent.shared.Networking.utils.HintOutbox)
local Registry = require(script.Parent.Parent.Actor.utils.ActorViewRegistryState)

type Job = Outbox.Job<PublicTypes.ActorView>
type Latest = Outbox.Latest<PublicTypes.ActorView>

local newOutbox: (Outbox.Pool, SharedTypes.DiagnosticCollector?, () -> number) -> Outbox.State<PublicTypes.ActorView> =
	Outbox.new

type Limits = {
	maxPending: number,
	maxPendingBytes: number,
	maxLatestKeys: number,
	maxAttempts: number,
	maxBytes: number,
	windowSeconds: number,
	maxRecords: number,
	maxSends: number,
	maxSequence: number,
}

local ClientHintRuntime = {}
ClientHintRuntime.__index = ClientHintRuntime

type State = {
	diagnostics: SharedTypes.DiagnosticCollector?,
	outbox: Outbox.State<PublicTypes.ActorView>,
	protocol: SharedTypes.ClientProtocol,
	codec: SharedTypes.HintCodec,
	stream: Types.ActorStreamRuntime,
	dependencies: Types.ClientHintDependencies,
	limits: Limits,
	window: number,
	attempts: number,
	rateBytes: number,
	pumping: boolean,
	destroyed: boolean,
}

type Runtime = typeof(setmetatable({} :: State, ClientHintRuntime))

function ClientHintRuntime._eligible(self: Runtime, actor: PublicTypes.ActorView?, handle: number?): boolean
	if actor == nil then
		return true
	end

	if not Registry.IsCurrent(actor) or not actor:IsAvailable() then
		return false
	end

	local record = self.stream:GetByActorId(actor:GetId())

	return record ~= nil and record.handle == handle and self.stream:GetByHandle(record.handle) == record
end

function ClientHintRuntime.ForgetActor(self: Runtime, actor: PublicTypes.ActorView): ()
	Outbox.ForgetActor(self.outbox, actor)
end

function ClientHintRuntime.Send(
	self: Runtime,
	id: string,
	actor: PublicTypes.ActorView?,
	payload: any?
): (boolean, string?)
	if self.destroyed or not self.dependencies.IsReady() then
		Metrics.Count(self.diagnostics, "hintRecordsRefused", 1)
		Metrics.Count(self.diagnostics, "hintsDropped", 1)

		return false, "ClientNotReady"
	end

	local now = self.dependencies.Now()

	if now - self.window >= self.limits.windowSeconds then
		self.window, self.attempts, self.rateBytes = now, 0, 0
	end

	if self.attempts >= self.limits.maxAttempts then
		Metrics.Count(self.diagnostics, "hintRecordsRefused", 1)
		Metrics.Count(self.diagnostics, "hintsDropped", 1)

		Metrics.Warn(self.diagnostics, "HintAbuse", "HintRateLimited")

		return false, "HintRateLimited"
	end

	self.attempts += 1

	local hint = if self.protocol.hintsById ~= nil then self.protocol.hintsById[id] else nil

	if hint == nil then
		Metrics.Count(self.diagnostics, "hintRecordsRefused", 1)
		Metrics.Count(self.diagnostics, "hintsDropped", 1)

		return false, "UnknownHint"
	elseif hint.direction ~= "ClientToServer" then
		Metrics.Count(self.diagnostics, "hintRecordsRefused", 1)
		Metrics.Count(self.diagnostics, "hintsDropped", 1)

		return false, "HintDirectionMismatch"
	end

	local handle: number? = nil

	if hint.target == "Actor" then
		if actor == nil or not Registry.IsCurrent(actor) or not actor:IsAvailable() then
			Metrics.Count(self.diagnostics, "hintRecordsRefused", 1)
			Metrics.Count(self.diagnostics, "hintsDropped", 1)

			return false, "ActorViewUnavailable"
		end

		local record = self.stream:GetByActorId(actor:GetId())

		if record == nil or self.stream:GetByHandle(record.handle) ~= record then
			Metrics.Count(self.diagnostics, "hintRecordsRefused", 1)
			Metrics.Count(self.diagnostics, "hintsDropped", 1)

			return false, "ActorViewUnavailable"
		end

		handle = record.handle
	elseif actor ~= nil then
		Metrics.Count(self.diagnostics, "hintRecordsRefused", 1)
		Metrics.Count(self.diagnostics, "hintsDropped", 1)

		return false, "UnexpectedActorTarget"
	end

	local key = tostring(hint.code) .. ":" .. tostring(handle or 0)
	local latest: Latest? = if hint.mode == "Latest" then self.outbox.latest[key] else nil

	if hint.mode == "Latest" then
		if latest == nil and self.outbox.latestCount >= self.limits.maxLatestKeys then
			Metrics.Count(self.diagnostics, "hintRecordsRefused", 1)
			Metrics.Count(self.diagnostics, "hintsDropped", 1)

			return false, "HintLatestKeysFull"
		end

		if latest ~= nil and latest.sequence >= self.limits.maxSequence then
			Metrics.Count(self.diagnostics, "hintRecordsRefused", 1)
			Metrics.Count(self.diagnostics, "hintsDropped", 1)

			return false, "HintSequenceExhausted"
		end
	end

	local previous = if latest ~= nil then latest.job else nil

	if previous == nil and self.outbox.pendingCount >= self.limits.maxPending then
		Metrics.Count(self.diagnostics, "hintRecordsRefused", 1)
		Metrics.Count(self.diagnostics, "hintsDropped", 1)

		Metrics.Warn(self.diagnostics, "HintAbuse", "HintPendingFull")

		return false, "HintPendingFull"
	end

	local sequence = if hint.mode == "Latest" then (if latest ~= nil then latest.sequence + 1 else 1) else nil

	local encoded, reason =
		self.codec.EncodeRecord({ hintCode = hint.code, targetHandle = handle, sequence = sequence, payload = payload })

	if encoded == nil then
		Metrics.Count(self.diagnostics, "hintRecordsRefused", 1)
		Metrics.Count(self.diagnostics, "hintsDropped", 1)

		return false, reason
	end

	local bytes = buffer.len(encoded)

	if self.rateBytes + bytes > self.limits.maxBytes then
		Metrics.Count(self.diagnostics, "hintRecordsRefused", 1)
		Metrics.Count(self.diagnostics, "hintsDropped", 1)

		Metrics.Warn(self.diagnostics, "HintAbuse", "HintRateLimited")

		return false, "HintRateLimited"
	end

	if
		self.outbox.pendingBytes + bytes - (if previous ~= nil then buffer.len(previous.bytes) else 0)
		> self.limits.maxPendingBytes
	then
		Metrics.Count(self.diagnostics, "hintRecordsRefused", 1)
		Metrics.Count(self.diagnostics, "hintsDropped", 1)

		Metrics.Warn(self.diagnostics, "HintAbuse", "HintPendingFull")

		return false, "HintPendingFull"
	end

	self.rateBytes += bytes

	Outbox.Admit(self.outbox, key, actor, handle, encoded, sequence, now)

	Metrics.Count(self.diagnostics, "hintRecordsAdmitted", 1)

	return true, nil
end

function ClientHintRuntime.Step(self: Runtime): (number, number)
	if self.destroyed or self.pumping or not self.dependencies.IsReady() then
		return 0, 0
	end

	self.pumping = true
	local work, sends = 0, 0

	while
		not self.destroyed
		and work < self.limits.maxRecords
		and sends < self.limits.maxSends
		and #self.outbox.queue > 0
	do
		local batch = Outbox.Select(self.outbox, self.limits.maxRecords - work, math.huge, function(job: Job): boolean
			return self:_eligible(job.actor, job.handle)
		end)

		work += batch.work
		local selected, records = batch.jobs, batch.records

		if #selected > 0 then
			local packet = self.codec.Pack(records)

			if packet ~= nil and not self.destroyed and self.dependencies.IsReady() then
				sends += 1
				local sender = coroutine.create(self.dependencies.SendUnreliable)
				local completed = coroutine.resume(sender, packet)

				if coroutine.status(sender) ~= "dead" then
					coroutine.close(sender)
					completed = false
				end

				Metrics.Count(self.diagnostics, if completed then "hintsSent" else "hintsDropped", #selected)

				if not completed then
					Metrics.Count(self.diagnostics, "hintSendFailures", 1)
					Metrics.Warn(self.diagnostics, "HintAbuse", "hintSendFailures")
				end
			else
				Metrics.Count(self.diagnostics, "hintsDropped", #selected)
			end

			Outbox.Settle(self.outbox, batch)
		end
	end

	self.pumping = false
	Metrics.Observe(self.diagnostics, "hintSendPumpWorkUnits", work)

	return work, sends
end

function ClientHintRuntime.Destroy(self: Runtime): ()
	if self.destroyed then
		return
	end

	self.destroyed = true

	Outbox.Destroy(self.outbox)

	if self.diagnostics ~= nil then
		self.diagnostics:SetAgeSource("hintSendQueueAgeSeconds", nil)
	end
end

function ClientHintRuntime.new(
	protocol: SharedTypes.ClientProtocol,
	stream: Types.ActorStreamRuntime,
	dependencies: Types.ClientHintDependencies,
	overrides: Types.ClientHintLimits?
): Types.ClientHintRuntime
	local options: Types.ClientHintLimits = overrides or {}

	local limits: Limits = {
		maxPending = options.maxPending or Constants.PENDING_RECORDS,
		maxPendingBytes = options.maxPendingBytes or Constants.PENDING_BYTES,
		maxLatestKeys = options.maxLatestKeys or Constants.LATEST_KEYS,
		maxAttempts = options.maxAttempts or Constants.CLIENT_ATTEMPTS,
		maxBytes = options.maxBytes or Constants.CLIENT_BYTES,
		windowSeconds = options.windowSeconds or Constants.WINDOW_SECONDS,
		maxRecords = options.maxRecords or Constants.STEP_RECORDS,
		maxSends = options.maxSends or Constants.STEP_SENDS,
		maxSequence = options.maxSequence or Constants.MAX_COUNTER,
	}

	for _, value in
		{
			limits.maxPending,
			limits.maxPendingBytes,
			limits.maxLatestKeys,
			limits.maxAttempts,
			limits.maxBytes,
			limits.windowSeconds,
			limits.maxRecords,
			limits.maxSends,
			limits.maxSequence,
		}
	do
		assert(value > 0 and value < math.huge, "InvalidHintLimits")
	end

	assert(limits.maxSequence <= Constants.MAX_COUNTER, "InvalidHintSequenceLimit")

	local state: State = {
		diagnostics = Diagnostics.Get(),
		outbox = newOutbox(Outbox.pool(), Diagnostics.Get(), dependencies.Now),
		protocol = protocol,
		codec = Codec.Compile(protocol),
		stream = stream,
		dependencies = dependencies,
		limits = limits,

		window = dependencies.Now(),
		attempts = 0,
		rateBytes = 0,
		pumping = false,
		destroyed = false,
	}

	local self: Runtime = setmetatable(state, ClientHintRuntime)

	if self.diagnostics ~= nil then
		self.diagnostics:SetAgeSource("hintSendQueueAgeSeconds", function(): number?
			local earliest: number? = nil

			for _, job in self.outbox.queue do
				if self:_eligible(job.actor, job.handle) then
					earliest = math.min(earliest or math.huge, job.queuedAt)
				end
			end

			return if earliest ~= nil then math.max(0, dependencies.Now() - earliest) else nil
		end)
	end

	return self :: Types.ClientHintRuntime
end

return ClientHintRuntime
