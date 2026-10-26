--!strict
local Types = require(script.Parent.types)
local PublicTypes = require(script.Parent.Parent.Actor.types)
local SharedTypes = require(script.Parent.Parent.Parent.shared.Networking.types)
local Metrics = require(script.Parent.Parent.Parent.shared.Networking.utils.NetworkingMetrics)
local Diagnostics = require(script.Parent.utils.NetworkingDiagnosticsState)
local Constants = require(script.Parent.Parent.Parent.shared.Networking.utils.HintConstants)
local Codec = require(script.Parent.Parent.Parent.shared.Networking.HintCodec)
local Registry = require(script.Parent.Parent.Actor.utils.ActorViewRegistryState)

type Latest = { sequence: number, actor: PublicTypes.ActorView?, job: Job? }
type Job = { queuedAt: number, bytes: buffer, actor: PublicTypes.ActorView?, handle: number?, latest: Latest? }

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
	protocol: SharedTypes.ClientProtocol,
	codec: SharedTypes.HintCodec,
	stream: Types.ActorStreamRuntime,
	dependencies: Types.ClientHintDependencies,
	limits: Limits,
	queue: { Job },
	latest: { [string]: Latest },
	pendingCount: number,
	pendingBytes: number,
	latestCount: number,
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

function ClientHintRuntime._release(self: Runtime, job: Job, dropped: boolean?): ()
	if dropped then
		Metrics.Count(self.diagnostics, "hintsDropped", 1)

		Metrics.Observe(
			self.diagnostics,
			"hintSendQueueResidenceSeconds",
			math.max(0, self.dependencies.Now() - job.queuedAt)
		)
	end

	self.pendingCount -= 1
	Metrics.Adjust(self.diagnostics, "hintSendRecords", -1)
	self.pendingBytes -= buffer.len(job.bytes)
	Metrics.Adjust(self.diagnostics, "hintSendBytes", -buffer.len(job.bytes))
end

function ClientHintRuntime.ForgetActor(self: Runtime, actor: PublicTypes.ActorView): ()
	for index = #self.queue, 1, -1 do
		local job = self.queue[index]

		if job.actor == actor then
			table.remove(self.queue, index)
			self:_release(job, true)
		end
	end

	for key, latest in self.latest do
		if latest.actor == actor then
			self.latest[key] = nil
			self.latestCount -= 1
			Metrics.Adjust(self.diagnostics, "hintLatestKeys", -1)
		end
	end
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
	local latest: Latest? = if hint.mode == "Latest" then self.latest[key] else nil

	if hint.mode == "Latest" then
		if latest == nil and self.latestCount >= self.limits.maxLatestKeys then
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

	if previous == nil and self.pendingCount >= self.limits.maxPending then
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
		self.pendingBytes + bytes - (if previous ~= nil then buffer.len(previous.bytes) else 0)
		> self.limits.maxPendingBytes
	then
		Metrics.Count(self.diagnostics, "hintRecordsRefused", 1)
		Metrics.Count(self.diagnostics, "hintsDropped", 1)

		Metrics.Warn(self.diagnostics, "HintAbuse", "HintPendingFull")

		return false, "HintPendingFull"
	end

	self.rateBytes += bytes

	if sequence ~= nil then
		if latest == nil then
			local created: Latest = { sequence = sequence, actor = actor }
			latest = created
			self.latest[key] = latest
			self.latestCount += 1
			Metrics.Adjust(self.diagnostics, "hintLatestKeys", 1)
		else
			latest.sequence = sequence
		end
	end

	if previous ~= nil then
		self.pendingBytes += bytes - buffer.len(previous.bytes)
		Metrics.Adjust(self.diagnostics, "hintSendBytes", bytes - buffer.len(previous.bytes))
		previous.bytes = encoded
		previous.queuedAt = now
		Metrics.Count(self.diagnostics, "hintsCoalesced", 1)
	else
		local job: Job = { queuedAt = now, bytes = encoded, actor = actor, handle = handle, latest = latest }
		table.insert(self.queue, job)
		self.pendingCount += 1
		Metrics.Adjust(self.diagnostics, "hintSendRecords", 1)
		self.pendingBytes += bytes
		Metrics.Adjust(self.diagnostics, "hintSendBytes", bytes)

		if latest ~= nil then
			latest.job = job
		end
	end

	Metrics.Count(self.diagnostics, "hintRecordsAdmitted", 1)

	return true, nil
end

function ClientHintRuntime.Step(self: Runtime): (number, number)
	if self.destroyed or self.pumping or not self.dependencies.IsReady() then
		return 0, 0
	end

	self.pumping = true
	local work, sends = 0, 0

	while not self.destroyed and work < self.limits.maxRecords and sends < self.limits.maxSends and #self.queue > 0 do
		local selected: { Job } = {}
		local records: { buffer } = {}
		local bytes = Constants.PACKET_HEADER_BYTES

		while
			not self.destroyed
			and work < self.limits.maxRecords
			and #records < Constants.MAX_RECORDS
			and #self.queue > 0
		do
			local job = self.queue[1]
			work += 1
			Metrics.Count(self.diagnostics, "hintSendVisits", 1)

			if self:_eligible(job.actor, job.handle) and bytes + buffer.len(job.bytes) > Constants.MAX_PACKET_BYTES then
				Metrics.Count(self.diagnostics, "hintUnproductiveInspections", 1)
				break
			end

			table.remove(self.queue, 1)

			Metrics.Observe(
				self.diagnostics,
				"hintSendQueueResidenceSeconds",
				math.max(0, self.dependencies.Now() - job.queuedAt)
			)

			if job.latest ~= nil then
				job.latest.job = nil
			end

			if self:_eligible(job.actor, job.handle) then
				table.insert(selected, job)
				table.insert(records, job.bytes)
				bytes += buffer.len(job.bytes)
			else
				Metrics.Count(self.diagnostics, "hintUnproductiveInspections", 1)
				self:_release(job, true)
			end
		end

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

			-- Selected records remain charged through reentrant transport/teardown.
			for _, job in selected do
				self:_release(job)
			end
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

	for _, job in self.queue do
		self:_release(job, true)
	end

	Metrics.Adjust(self.diagnostics, "hintLatestKeys", -self.latestCount)

	if self.diagnostics ~= nil then
		self.diagnostics:SetAgeSource("hintSendQueueAgeSeconds", nil)
	end

	self.queue, self.latest, self.latestCount = {}, {}, 0
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
		protocol = protocol,
		codec = Codec.Compile(protocol),
		stream = stream,
		dependencies = dependencies,
		limits = limits,
		queue = {},
		latest = {},
		pendingCount = 0,
		pendingBytes = 0,
		latestCount = 0,
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

			for _, job in self.queue do
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
