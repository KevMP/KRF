--!strict
local Types = require(script.Parent.AwarenessTypes)
local ActorTypes = require(script.Parent.Parent.Actor.types)
local WireTypes = require(script.Parent.Parent.Parent.shared.Networking.ActorStreamTypes)
local PublicationTypes = require(script.Parent.PublicationTypes)
local Scheduler = require(script.Parent.PublicationScheduler)
local Constants = require(script.Parent.Parent.Parent.shared.Networking.ActorProtocolConstants)
local ProjectionTypes = require(script.Parent.ActorRecipientProjection)

export type Dependencies = {
	Project: (ActorTypes.Actor, Player) -> (number?, ProjectionTypes.Projection?, string?),
	Activate: (Stream) -> (),
	ReportFault: (Types.Fault) -> (),
}
type Baseline = { body: buffer, offset: number, phase: "Begin" | "Chunks" }
type StreamState = {
	actor: ActorTypes.Actor,
	player: Player,
	handle: number,
	generation: number,
	revision: number,
	fence: number,
	identitySent: boolean,
	baseline: Baseline?,
	recapture: boolean,
	removed: boolean,
	failed: boolean,
	active: boolean,
	scheduler: PublicationTypes.Scheduler,
	key: PublicationTypes.StreamKey,
	options: Types.Options,
	dependencies: Dependencies,
}
local ActorRecipientStream = {}
ActorRecipientStream.__index = ActorRecipientStream
export type Stream = typeof(setmetatable({} :: StreamState, ActorRecipientStream))

function ActorRecipientStream.Fault(self: Stream, reason: string): ()
	local reported: boolean = self.failed
	self.failed = true
	self.baseline = nil
	self.recapture = false
	self.removed = false
	self.scheduler:Destroy()
	if not reported then
		self.dependencies.ReportFault({ player = self.player, actorId = self.actor:GetId(), reason = reason })
	end
end

function ActorRecipientStream.Capture(self: Stream): boolean
	local sequence: number?, projected: ProjectionTypes.Projection?, reason: string? =
		self.dependencies.Project(self.actor, self.player)
	if sequence == nil or projected == nil or projected.body == nil then
		self:Fault(reason or "InvalidActorBaseline")
		return false
	end
	local body: buffer = projected.body
	if buffer.len(body) > self.options.maxBaselineBytes then
		self:Fault("ActorBaselineTooLarge")
		return false
	end
	if self.generation >= (self.options.maxGeneration or Constants.MAX_COUNTER) then
		self:Fault("ActorGenerationExhausted")
		return false
	end
	self.generation += 1
	self.fence = sequence
	self.baseline = { body = body, offset = 0, phase = "Begin" }
	self.recapture = false
	self.scheduler:ResetAfterBaseline(self.key, projected.domains)
	self.dependencies.Activate(self)
	return true
end

function ActorRecipientStream.new(
	actor: ActorTypes.Actor,
	player: Player,
	handle: number,
	codec: WireTypes.Codec,
	options: Types.Options,
	dependencies: Dependencies
): Stream
	local scheduler: PublicationTypes.Scheduler = Scheduler.new({
		maxBarriers = options.maxEvents,
		maxEvents = options.maxEvents,
		maxQueuedBytes = options.maxQueuedBytes,
		MeasureRecord = function(commit: PublicationTypes.FilteredCommit): number
			local size: number? = codec.Measure({
				{ kind = "Commit", handle = 1, revision = 1, patches = commit.patches, events = commit.events },
			})
			return size or math.huge
		end,
	})
	local state: StreamState = {
		actor = actor,
		player = player,
		handle = handle,
		generation = 0,
		revision = 0,
		fence = 0,
		identitySent = false,
		baseline = nil,
		recapture = false,
		removed = false,
		failed = false,
		active = false,
		scheduler = scheduler,
		key = { recipient = player, actor = actor },
		options = options,
		dependencies = dependencies,
	}
	return setmetatable(state, ActorRecipientStream)
end

function ActorRecipientStream.Prepare(self: Stream, maxBytes: number, canBegin: boolean): WireTypes.Record?
	if self.removed then
		return { kind = "ActorRemove", handle = self.handle }
	end
	if self.failed then
		return nil
	end
	if self.recapture and not self:Capture() then
		return nil
	end
	local pending: Baseline? = self.baseline
	if pending ~= nil then
		if pending.phase == "Begin" then
			if not canBegin then
				return nil
			end
			return {
				kind = "BaselineBegin",
				handle = self.handle,
				actorId = if self.identitySent then nil else self.actor:GetId(),
				generation = self.generation,
				totalBytes = buffer.len(pending.body),
			}
		elseif pending.offset < buffer.len(pending.body) then
			-- Header and fixed Chunk framing consume 26 bytes in a single-record packet.
			local length: number =
				math.min(self.options.maxChunkBytes, buffer.len(pending.body) - pending.offset, maxBytes - 26)
			if length <= 0 then
				return nil
			end
			local chunk: buffer = buffer.create(length)
			buffer.copy(chunk, 0, pending.body, pending.offset, length)
			return {
				kind = "BaselineChunk",
				handle = self.handle,
				generation = self.generation,
				offset = pending.offset,
				bytes = chunk,
			}
		end
		if self.revision >= self.options.maxRevision then
			self:Fault("ActorRevisionExhausted")
			return nil
		end
		return {
			kind = "BaselineEnd",
			handle = self.handle,
			generation = self.generation,
			revision = self.revision + 1,
		}
	end
	if self.scheduler:GetStreamStatus(self.key).pendingRecords == 0 then
		return nil
	end
	if self.revision >= self.options.maxRevision then
		self:Fault("ActorRevisionExhausted")
		return nil
	end
	local nextBytes: number? = self.scheduler:GetNextRecordBytes(self.key)
	if nextBytes ~= nil and nextBytes > Constants.STEP_BYTES then
		-- This record cannot fit any pass. Recover canonical truth through bounded chunks;
		-- event barriers are discarded by the same recovery contract as queue overload.
		self.recapture = true
		if not self:Capture() then
			return nil
		end
		return self:Prepare(maxBytes, canBegin)
	end
	local drained: PublicationTypes.DrainResult = self.scheduler:DrainBudgeted(maxBytes, 1)
	local record: PublicationTypes.Record? = drained.records[1]
	if record == nil then
		return nil
	end
	return {
		kind = "Commit",
		handle = self.handle,
		revision = self.revision + 1,
		patches = record.commit.patches,
		events = record.commit.events,
	}
end

function ActorRecipientStream.Sent(self: Stream, record: WireTypes.Record): ()
	local pending: Baseline? = self.baseline
	if record.kind == "BaselineBegin" then
		self.identitySent = true
		if pending ~= nil and record.generation == self.generation then
			pending.phase = "Chunks"
		end
	elseif record.kind == "BaselineChunk" then
		if pending ~= nil and record.generation == self.generation then
			pending.offset += buffer.len(record.bytes)
		end
	elseif record.kind == "BaselineEnd" then
		if record.generation == self.generation then
			self.baseline = nil
		end
		self.revision = record.revision
	elseif record.kind == "Commit" then
		self.revision = record.revision
	else
		self.removed = false
	end
end

function ActorRecipientStream.Enqueue(self: Stream, commit: PublicationTypes.FilteredCommit): ()
	if self.failed or self.recapture or commit.sequence <= self.fence then
		return
	end
	if #commit.patches == 0 and #commit.events == 0 then
		return
	end
	if not self.scheduler:Enqueue(self.key, commit) then
		self.recapture = true
		self.baseline = nil
	end
	self.dependencies.Activate(self)
end

function ActorRecipientStream.Retire(self: Stream): ()
	self.scheduler:Destroy()
	self.baseline = nil
	self.recapture = false
	self.removed = true
	self.dependencies.Activate(self)
end

function ActorRecipientStream.HasWork(self: Stream): boolean
	return self.baseline ~= nil
		or self.recapture
		or self.removed
		or self.scheduler:GetStreamStatus(self.key).pendingRecords > 0
end

function ActorRecipientStream.Destroy(self: Stream): ()
	self.scheduler:Destroy()
end

return ActorRecipientStream
