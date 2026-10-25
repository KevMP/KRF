--!strict
local Types = require(script.Parent.types)
local PublicTypes = require(script.Parent.Parent.Actor.types)
local SharedTypes = require(script.Parent.Parent.Parent.shared.Networking.types)
local Constants = require(script.Parent.Parent.Parent.shared.Networking.utils.HintConstants)
local Codec = require(script.Parent.Parent.Parent.shared.Networking.HintCodec)
local Registry = require(script.Parent.Parent.Actor.utils.ActorViewRegistryState)

type Latest = { sequence: number, actor: PublicTypes.ActorView?, job: Job? }
type Job = { bytes: buffer, actor: PublicTypes.ActorView?, handle: number?, latest: Latest? }

local ClientHintRuntime = {}
ClientHintRuntime.__index = ClientHintRuntime

type State = {
	protocol: SharedTypes.ClientProtocol,
	codec: SharedTypes.HintCodec,
	stream: Types.ActorStreamRuntime,
	dependencies: Types.ClientHintDependencies,
	limits: { [string]: number },
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

function ClientHintRuntime._release(self: Runtime, job: Job): ()
	self.pendingCount -= 1
	self.pendingBytes -= buffer.len(job.bytes)
end

function ClientHintRuntime.ForgetActor(self: Runtime, actor: PublicTypes.ActorView): ()
	for index = #self.queue, 1, -1 do
		local job = self.queue[index]

		if job.actor == actor then
			table.remove(self.queue, index)
			self:_release(job)
		end
	end

	for key, latest in self.latest do
		if latest.actor == actor then
			self.latest[key] = nil
			self.latestCount -= 1
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
		return false, "ClientNotReady"
	end

	local now = self.dependencies.Now()

	if now - self.window >= self.limits.windowSeconds then
		self.window, self.attempts, self.rateBytes = now, 0, 0
	end

	if self.attempts >= self.limits.maxAttempts then
		return false, "HintRateLimited"
	end

	self.attempts += 1

	local hint = if self.protocol.hintsById ~= nil then self.protocol.hintsById[id] else nil

	if hint == nil then
		return false, "UnknownHint"
	elseif hint.direction ~= "ClientToServer" then
		return false, "HintDirectionMismatch"
	end

	local handle: number? = nil

	if hint.target == "Actor" then
		if actor == nil or not Registry.IsCurrent(actor) or not actor:IsAvailable() then
			return false, "ActorViewUnavailable"
		end

		local record = self.stream:GetByActorId(actor:GetId())

		if record == nil or self.stream:GetByHandle(record.handle) ~= record then
			return false, "ActorViewUnavailable"
		end

		handle = record.handle
	elseif actor ~= nil then
		return false, "UnexpectedActorTarget"
	end

	local key = tostring(hint.code) .. ":" .. tostring(handle or 0)
	local latest: Latest? = if hint.mode == "Latest" then self.latest[key] else nil

	if hint.mode == "Latest" then
		if latest == nil and self.latestCount >= self.limits.maxLatestKeys then
			return false, "HintLatestKeysFull"
		end

		if latest ~= nil and latest.sequence >= self.limits.maxSequence then
			return false, "HintSequenceExhausted"
		end
	end

	local previous = if latest ~= nil then latest.job else nil

	if previous == nil and self.pendingCount >= self.limits.maxPending then
		return false, "HintPendingFull"
	end

	local sequence = if hint.mode == "Latest" then (if latest ~= nil then latest.sequence + 1 else 1) else nil

	local encoded, reason =
		self.codec.EncodeRecord({ hintCode = hint.code, targetHandle = handle, sequence = sequence, payload = payload })

	if encoded == nil then
		return false, reason
	end

	local bytes = buffer.len(encoded)

	if self.rateBytes + bytes > self.limits.maxBytes then
		return false, "HintRateLimited"
	end

	if
		self.pendingBytes + bytes - (if previous ~= nil then buffer.len(previous.bytes) else 0)
		> self.limits.maxPendingBytes
	then
		return false, "HintPendingFull"
	end

	self.rateBytes += bytes

	if sequence ~= nil then
		if latest == nil then
			local created: Latest = { sequence = sequence, actor = actor }
			latest = created
			self.latest[key] = latest
			self.latestCount += 1
		else
			latest.sequence = sequence
		end
	end

	if previous ~= nil then
		self.pendingBytes += bytes - buffer.len(previous.bytes)
		previous.bytes = encoded
	else
		local job: Job = { bytes = encoded, actor = actor, handle = handle, latest = latest }
		table.insert(self.queue, job)
		self.pendingCount += 1
		self.pendingBytes += bytes

		if latest ~= nil then
			latest.job = job
		end
	end

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

			if self:_eligible(job.actor, job.handle) and bytes + buffer.len(job.bytes) > Constants.MAX_PACKET_BYTES then
				break
			end

			table.remove(self.queue, 1)

			if job.latest ~= nil then
				job.latest.job = nil
			end

			if self:_eligible(job.actor, job.handle) then
				table.insert(selected, job)
				table.insert(records, job.bytes)
				bytes += buffer.len(job.bytes)
			else
				self:_release(job)
			end
		end

		if #selected > 0 then
			local packet = self.codec.Pack(records)

			if packet ~= nil and not self.destroyed and self.dependencies.IsReady() then
				sends += 1
				local sender = coroutine.create(self.dependencies.SendUnreliable)
				coroutine.resume(sender, packet)

				if coroutine.status(sender) ~= "dead" then
					coroutine.close(sender)
				end
			end

			-- Selected records remain charged through reentrant transport/teardown.
			for _, job in selected do
				self:_release(job)
			end
		end
	end

	self.pumping = false

	return work, sends
end

function ClientHintRuntime.Destroy(self: Runtime): ()
	if self.destroyed then
		return
	end

	self.destroyed = true

	for _, job in self.queue do
		self:_release(job)
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

	local limits = {
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

	for _, value in limits do
		assert(value > 0 and value < math.huge, "InvalidHintLimits")
	end

	assert(limits.maxSequence <= Constants.MAX_COUNTER, "InvalidHintSequenceLimit")

	local state: State = {
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

	return self :: Types.ClientHintRuntime
end

return ClientHintRuntime
