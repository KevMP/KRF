--!strict
local Types = require(script.Parent.Parent.types)
local ActorTypes = require(script.Parent.Parent.Parent.Actor.types)
local SharedNetworkingTypes = require(script.Parent.Parent.Parent.Parent.shared.Networking.types)
local Metrics = require(script.Parent.Parent.Parent.Parent.shared.Networking.utils.NetworkingMetrics)
local Diagnostics = require(script.Parent.NetworkingDiagnosticsState)
local Scheduler = require(script.Parent.PublicationScheduler)
local Constants = require(script.Parent.Parent.Parent.Parent.shared.Networking.utils.ActorProtocolConstants)
local ProjectionTypes = require(script.Parent.ActorRecipientProjection)
local ActiveQueue = require(script.Parent.ActiveQueue)
local WorkBudget = require(script.Parent.ReliableWorkBudget)

export type Dependencies = {
	Now: (() -> number)?,
	Backlog: Types.ReliableBacklog,
	Current: () -> boolean,
	DiscardProjection: (ActorTypes.Actor, ProjectionTypes.Projection) -> (),
	GetOrder: (() -> number)?,
	GetEpoch: () -> number,
	Anchor: (ActorTypes.Actor, Player) -> (number?, ProjectionTypes.Projection?, string?),
	Project: (ActorTypes.Actor, Player, ProjectionTypes.Projection) -> (number?, ProjectionTypes.Projection?, string?),
	Activate: (Stream) -> (),
	ReportFault: (Types.ActorAwarenessFault) -> (),
	MeasureRecord: (Types.PublicationFilteredCommit) -> number,
	ClaimCapture: (Stream, WorkBudget.Budget) -> boolean,
	YieldCapture: (Stream) -> (),
}

type Baseline = {
	queuedAt: number,
	body: buffer?,
	projection: ProjectionTypes.Projection,
	offset: number,
	phase: "Begin" | "Chunks",
	order: number,
	charge: Types.PublicationCharge?,
}

type StreamState = {
	diagnostics: SharedNetworkingTypes.DiagnosticCollector?,
	recaptureQueuedAt: number,
	terminalQueuedAt: number,
	queueNode: ActiveQueue.Node<Stream>?,
	captureNode: ActiveQueue.Node<Stream>?,
	orderIndex: number,
	pendingOrder: number,
	stagedOrder: number?,
	stagedCharge: Types.PublicationCharge?,
	stagedBaselineCharge: Types.PublicationCharge?,
	terminalOrder: number,
	actor: ActorTypes.Actor,
	player: Player,
	handle: number,
	generation: number,
	revision: number,
	fence: number,
	identitySent: boolean,
	baseline: Baseline?,
	recapture: boolean,
	recaptureOrder: number,
	retryAt: number,
	retryDelay: number,
	blockedBudget: number?,
	removed: boolean,
	failed: boolean,
	haltPending: boolean,
	active: boolean,
	scheduler: Types.PublicationScheduler,
	key: Types.PublicationStreamKey,
	options: Types.ActorAwarenessOptions,
	dependencies: Dependencies,
}

local ActorRecipientStream = {}
ActorRecipientStream.__index = ActorRecipientStream

export type Stream = typeof(setmetatable({} :: StreamState, ActorRecipientStream))

function ActorRecipientStream.ResetRecovery(self: Stream, completed: boolean?): ()
	if self.diagnostics ~= nil and self.retryDelay > 0 and self.dependencies.Current() then
		Metrics.Adjust(self.diagnostics, "recoveryStreams", -1)

		if not completed then
			Metrics.Count(self.diagnostics, "recoveryAbandoned", 1)
		end
	end

	self.retryAt, self.retryDelay = 0, 0
end

function ActorRecipientStream.CanCapture(self: Stream): boolean
	return self.dependencies.Current() and self.dependencies.GetEpoch() >= self.retryAt
end

function ActorRecipientStream.NeedsCapture(self: Stream): boolean
	return self.recapture or (self.baseline ~= nil and self.baseline.body == nil)
end

function ActorRecipientStream._backoff(self: Stream): ()
	if self.diagnostics ~= nil and self.dependencies.Current() then
		Metrics.Count(self.diagnostics, "recoveryBackoffs", 1)

		if self.retryDelay == 0 then
			Metrics.Adjust(self.diagnostics, "recoveryStreams", 1)
		end
	end

	self.retryDelay = math.min(
		if self.retryDelay == 0 then Constants.RECOVERY_RETRY_PUMPS else self.retryDelay * 2,
		Constants.MAX_RECOVERY_RETRY_PUMPS
	)

	self.retryAt = self.dependencies.GetEpoch() + self.retryDelay
	-- Install ownership before a log sink can close this connection reentrantly.
	Metrics.Warn(self.diagnostics, "BaselineRecovery", "BaselineRetryBackoff")
end

function ActorRecipientStream._observeBaselineEnd(self: Stream, completed: boolean?): ()
	if self.diagnostics ~= nil and self.baseline ~= nil and self.dependencies.Current() then
		Metrics.Adjust(self.diagnostics, "baselineGenerations", -1)
		Metrics.Count(self.diagnostics, if completed then "baselinesCompleted" else "baselinesAbandoned", 1)

		Metrics.Observe(
			self.diagnostics,
			"reliableQueueResidenceSeconds",
			math.max(0, (self.dependencies.Now or os.clock)() - self.baseline.queuedAt)
		)
	end
end

function ActorRecipientStream._clearBaseline(self: Stream, completed: boolean?): ()
	self:_observeBaselineEnd(completed)

	if self.baseline ~= nil and self.baseline.charge ~= nil and self.baseline.charge ~= self.stagedBaselineCharge then
		self.baseline.charge.release()
	end

	-- A selected transfer remains owned by the pump even after invalidation.
	self.baseline = nil
end

function ActorRecipientStream.StageBaseline(self: Stream): ()
	if self.baseline ~= nil and self.baseline.charge ~= nil then
		self.stagedBaselineCharge = self.baseline.charge
		self.baseline.charge.stage()
	end
end

function ActorRecipientStream.ReleaseStaged(self: Stream): ()
	if self.stagedCharge ~= nil then
		self.stagedCharge.release()
		self.stagedCharge = nil
	end

	if self.stagedBaselineCharge ~= nil then
		local charge = self.stagedBaselineCharge

		self.stagedBaselineCharge = nil

		if self.baseline ~= nil and self.baseline.charge == charge then
			charge.resume()
		else
			charge.release()
		end
	end
end

function ActorRecipientStream.Fault(self: Stream, reason: string): ()
	self.terminalQueuedAt = (self.dependencies.Now or os.clock)()
	self.terminalOrder = if self.dependencies.GetOrder ~= nil then self.dependencies.GetOrder() else 0

	local reported: boolean = self.failed

	self.failed = true
	self:ResetRecovery()
	self:_clearBaseline()
	self.recapture = false
	self.blockedBudget = nil
	-- A known identity needs reliable cleanup, even if failure happened after End.
	-- Failed cleanup remains pending until its reliable send succeeds.
	self.removed = self.removed and self.identitySent

	if not reported then
		self.haltPending = self.identitySent and not self.removed
	end

	self.scheduler:Destroy()

	self.dependencies.Activate(self)

	if not reported then
		self.dependencies.ReportFault({ player = self.player, actorId = self.actor:GetId(), reason = reason })
	end
end

-- Preserve the synchronous N4 boundary using only N3-owned value references.
-- Recipient projection/encoding runs later under _prepareBaseline's work claim.
function ActorRecipientStream.Capture(self: Stream): boolean
	local queuedAt = self:GetQueuedAt() or (self.dependencies.Now or os.clock)()

	local earliest = self:GetNextOrder()
		or (if self.dependencies.GetOrder ~= nil then self.dependencies.GetOrder() else 0)

	local sequence: number?, projected: ProjectionTypes.Projection?, reason: string? =
		self.dependencies.Anchor(self.actor, self.player)

	if sequence == nil or projected == nil then
		self:Fault(reason or "InvalidActorBaseline")

		return false
	end

	if self.generation >= (self.options.maxGeneration or Constants.MAX_COUNTER) then
		self.dependencies.DiscardProjection(self.actor, projected)
		self:Fault("ActorGenerationExhausted")

		return false
	end

	if not self.dependencies.Current() then
		self.dependencies.DiscardProjection(self.actor, projected)

		return false
	end

	-- N3 already measured the anchored visible truth. An invalid baseline must
	-- fault before a backlog refusal can turn it into permanent recovery work.
	if projected.encodedSizeBytes > self.options.maxBaselineBytes then
		self.dependencies.DiscardProjection(self.actor, projected)
		self:Fault("ActorBaselineTooLarge")

		return false
	end

	local charge = self.dependencies.Backlog:Acquire(
		self.key,
		projected,
		projected.retainedBytes,
		if self.baseline ~= nil and self.baseline.charge ~= self.stagedBaselineCharge then self.baseline.charge else nil,
		true,
		function(): ()
			self.dependencies.DiscardProjection(self.actor, projected)
		end
	)

	if charge == nil then
		Metrics.Count(self.diagnostics, "baselineCapacityRefusals", 1)
		self.dependencies.DiscardProjection(self.actor, projected)

		self:_clearBaseline()
		self.scheduler:MarkBaselinePending(self.key)
		self.recapture, self.recaptureOrder = true, earliest
		self.recaptureQueuedAt = queuedAt
		self:_backoff()
		self.dependencies.Activate(self)

		return false
	end

	if self.baseline ~= nil then
		if self.baseline.charge ~= charge then
			self:_clearBaseline()
		else
			-- A new generation can reuse the same owned anchor. End only its
			-- semantic observation; the ledger charge must remain untouched.
			self:_observeBaselineEnd(false)
		end
	end

	Metrics.Count(self.diagnostics, "baselinesCaptured", 1)
	Metrics.Count(self.diagnostics, "baselinesRestarted", if self.generation > 0 then 1 else 0)
	Metrics.Adjust(self.diagnostics, "baselineGenerations", 1)
	self.generation += 1
	self.fence = sequence

	self.baseline = {
		queuedAt = queuedAt,
		charge = charge,
		projection = projected,
		body = projected.body,
		offset = 0,
		phase = "Begin",
		order = earliest,
	}

	self.recapture = false
	self.blockedBudget = nil
	self.scheduler:ResetAfterBaseline(self.key, projected.domains, false, true)
	self.dependencies.Activate(self)

	return true
end

function ActorRecipientStream._prepareBaseline(self: Stream, work: WorkBudget.Budget): boolean
	if not self:CanCapture() then
		return false
	end

	self.dependencies.Activate(self)

	if not self.dependencies.ClaimCapture(self, work) then
		return false
	end

	if self.recapture and not self:Capture() then
		return false
	end

	local pending = self.baseline
	assert(pending ~= nil, "Expected anchored baseline")
	self:StageBaseline()
	local _, projected, reason = self.dependencies.Project(self.actor, self.player, pending.projection)

	-- Projection dependencies can invalidate/replace the selected generation.
	if self.baseline ~= pending or not self.dependencies.Current() then
		return false
	end

	if projected == nil or projected.body == nil then
		self:Fault(reason or "InvalidActorBaseline")

		return false
	end

	if buffer.len(projected.body) > self.options.maxBaselineBytes then
		self:Fault("ActorBaselineTooLarge")

		return false
	end

	pending.body = projected.body
	-- Retain every commit queued after the synchronous anchor's fence.
	self.scheduler:ResetAfterBaseline(self.key, projected.domains, true, true)

	return true
end

function ActorRecipientStream.new(
	actor: ActorTypes.Actor,
	player: Player,
	handle: number,
	options: Types.ActorAwarenessOptions,
	dependencies: Dependencies
): Stream
	local diagnostics = Diagnostics.FindConnection(player)

	local scheduler: Types.PublicationScheduler = Scheduler.new({
		diagnostics = diagnostics,
		IsCurrent = dependencies.Current,
		Now = dependencies.Now,
		backlog = dependencies.Backlog,
		retainDrained = true,
		maxBarriers = options.maxEvents,
		maxEvents = options.maxEvents,
		maxQueuedBytes = options.maxQueuedBytes,
		MeasureRecord = dependencies.MeasureRecord,
	})

	local state: StreamState = {
		diagnostics = diagnostics,
		recaptureQueuedAt = 0,
		terminalQueuedAt = 0,
		orderIndex = 0,
		pendingOrder = 0,
		terminalOrder = 0,
		actor = actor,
		player = player,
		handle = handle,
		generation = 0,
		revision = 0,
		fence = 0,
		identitySent = false,
		baseline = nil,
		recapture = false,
		recaptureOrder = 0,
		retryAt = 0,
		retryDelay = 0,
		blockedBudget = nil,
		removed = false,
		failed = false,
		haltPending = false,
		active = false,
		scheduler = scheduler,
		key = { recipient = player, actor = actor },
		options = options,
		dependencies = dependencies,
	}

	return setmetatable(state, ActorRecipientStream)
end

function ActorRecipientStream._begin(self: Stream, canBegin: boolean): SharedNetworkingTypes.ActorStreamRecord?
	if not canBegin then
		return nil
	end

	local pending = self.baseline
	assert(pending ~= nil, "Expected captured baseline")

	return {
		kind = "BaselineBegin",
		handle = self.handle,
		actorId = if self.identitySent then nil else self.actor:GetId(),
		generation = self.generation,
		totalBytes = buffer.len(assert(pending.body, "Expected encoded baseline")),
	}
end

function ActorRecipientStream.Prepare(
	self: Stream,
	maxBytes: number,
	canBegin: boolean,
	deliveryBudget: number,
	maxOrder: number?,
	work: WorkBudget.Budget
): (SharedNetworkingTypes.ActorStreamRecord?, number?)
	if not WorkBudget.Take(work, "prepares") then
		return nil, nil
	end

	if maxOrder ~= nil and not WorkBudget.Take(work, "checks") then
		return nil, nil
	end

	if maxOrder ~= nil and not self:HasWorkThrough(maxOrder) then
		self.dependencies.YieldCapture(self)

		return nil, nil
	end

	if self.removed then
		return { kind = "ActorRemove", handle = self.handle }, nil
	end

	if self.haltPending then
		return { kind = "ActorHalt", handle = self.handle }, nil
	end

	if self.failed then
		return nil, nil
	end

	if self:NeedsCapture() then
		if not self:_prepareBaseline(work) then
			return nil, nil
		end
	end

	local pending: Baseline? = self.baseline

	if pending ~= nil then
		self:StageBaseline()
		local body = assert(pending.body, "Expected encoded baseline")

		if pending.phase == "Begin" then
			return self:_begin(canBegin), nil
		elseif pending.offset < buffer.len(body) then
			-- Header and fixed Chunk framing consume 26 bytes in a single-record packet.
			local length: number =
				math.min(self.options.maxChunkBytes, buffer.len(body) - pending.offset, maxBytes - 26)

			if length <= 0 then
				return nil, nil
			end

			local chunk: buffer = buffer.create(length)
			buffer.copy(chunk, 0, body, pending.offset, length)

			return {
				kind = "BaselineChunk",
				handle = self.handle,
				generation = self.generation,
				offset = pending.offset,
				bytes = chunk,
			},
				nil
		end

		if self.revision >= self.options.maxRevision then
			self:Fault("ActorRevisionExhausted")

			return nil, nil
		end

		return {
			kind = "BaselineEnd",
			handle = self.handle,
			generation = self.generation,
			revision = self.revision + 1,
		},
			nil
	end

	if self.scheduler:GetStreamStatus(self.key).pendingRecords == 0 then
		return nil, nil
	end

	if self.revision >= self.options.maxRevision then
		self:Fault("ActorRevisionExhausted")

		return nil, nil
	end

	local nextBytes: number? = self.scheduler:GetNextRecordBytes(self.key)

	if nextBytes ~= nil and nextBytes > deliveryBudget then
		-- Give a transiently small pass a chance to recover its budget. Repeated
		-- insufficient full passes recover truth; a small remaining budget only waits.
		if self.blockedBudget == nil or deliveryBudget > self.blockedBudget then
			self.blockedBudget = deliveryBudget

			return nil, nil
		end

		Metrics.Count(self.diagnostics, "streamDiscontinuities", 1)
		self.recaptureQueuedAt = self:GetQueuedAt() or (self.dependencies.Now or os.clock)()
		self.recapture = true
		self.recaptureOrder = self.scheduler:GetNextRecordOrder(self.key) or 0
		self.scheduler:MarkBaselinePending(self.key)
		self.dependencies.Activate(self)

		if not self:_prepareBaseline(work) then
			return nil, nil
		end

		self:StageBaseline()

		return self:_begin(canBegin), nil
	end

	self.blockedBudget = nil

	local drained: Types.PublicationDrainResult = self.scheduler:DrainBudgeted(maxBytes, 1)
	local record: Types.PublicationRecord? = drained.records[1]

	if record == nil then
		return nil, nil
	end

	self.stagedCharge = record.charge

	return {
		kind = "Commit",
		handle = self.handle,
		revision = self.revision + 1,
		patches = record.commit.patches,
		events = record.commit.events,
	},
		record.encodedSizeBytes
end

function ActorRecipientStream.Sent(self: Stream, record: SharedNetworkingTypes.ActorStreamRecord): ()
	local pending: Baseline? = self.baseline

	if record.kind == "BaselineBegin" then
		self.identitySent = true

		-- A fault can occur reentrantly before the Begin send returns successfully.
		if self.failed and not self.removed then
			self.haltPending = true
			self.dependencies.Activate(self)
		end

		if pending ~= nil and record.generation == self.generation then
			pending.phase = "Chunks"
		end
	elseif record.kind == "BaselineChunk" then
		if pending ~= nil and record.generation == self.generation then
			pending.offset += buffer.len(record.bytes)
		end
	elseif record.kind == "BaselineEnd" then
		if record.generation == self.generation then
			self:_clearBaseline(true)

			if pending ~= nil then
				self:ResetRecovery(true)
			end
		end

		self.revision = record.revision
	elseif record.kind == "Commit" then
		self.revision = record.revision
	elseif record.kind == "ActorHalt" then
		self.haltPending = false
	else
		self.removed = false
		self.haltPending = false
	end
end

function ActorRecipientStream.Enqueue(self: Stream, commit: Types.PublicationFilteredCommit, order: number?): ()
	if self.failed or self.recapture or commit.sequence <= self.fence then
		if commit.sequence > self.fence and (#commit.patches > 0 or #commit.events > 0) then
			Metrics.Count(self.diagnostics, "publicationDropped", 1)
		end

		return
	end

	if #commit.patches == 0 and #commit.events == 0 then
		return
	end

	local pendingOrder: number? = if self.baseline ~= nil
		then self.baseline.order
		else self.scheduler:GetNextRecordOrder(self.key)

	if self.stagedOrder ~= nil then
		pendingOrder = math.min(pendingOrder or math.huge, self.stagedOrder)
	end

	local queuedAt = self:GetQueuedAt() or (self.dependencies.Now or os.clock)()

	if not self.scheduler:Enqueue(self.key, commit, order) then
		self.recaptureQueuedAt = queuedAt

		if self.baseline ~= nil then
			self:_backoff()
		end

		self.recapture = true

		-- Replacement truth keeps the earliest work it supersedes ahead of newer results.
		self.recaptureOrder = pendingOrder
			or order
			or (if self.dependencies.GetOrder ~= nil then self.dependencies.GetOrder() else 0)

		self:_clearBaseline()
	end

	self.dependencies.Activate(self)
end

function ActorRecipientStream.Retire(self: Stream): ()
	self:ResetRecovery()
	self.terminalQueuedAt = (self.dependencies.Now or os.clock)()
	self.terminalOrder = if self.dependencies.GetOrder ~= nil then self.dependencies.GetOrder() else 0
	self.scheduler:Destroy()
	self:_clearBaseline()
	self.recapture = false
	self.haltPending = false
	self.removed = true
	self.dependencies.Activate(self)
end

function ActorRecipientStream.GetQueuedAt(self: Stream): number?
	if self.removed or self.haltPending then
		return self.terminalQueuedAt
	end

	if self.failed then
		return nil
	end

	if self.recapture then
		return self.recaptureQueuedAt
	end

	if self.baseline ~= nil then
		return self.baseline.queuedAt
	end

	return self.scheduler:GetNextRecordQueuedAt(self.key)
end

function ActorRecipientStream.GetEligibleQueuedAt(self: Stream): number?
	return if self:NeedsCapture() and not self:CanCapture() then nil else self:GetQueuedAt()
end

function ActorRecipientStream.HasWork(self: Stream): boolean
	return self.baseline ~= nil
		or self.recapture
		or self.removed
		or self.haltPending
		or self.scheduler:GetStreamStatus(self.key).pendingRecords > 0
end

function ActorRecipientStream.GetNextOrder(self: Stream): number?
	if self.removed or self.haltPending then
		return self.terminalOrder
	end

	if self.failed then
		return nil
	end

	local order = if self.recapture
		then self.recaptureOrder
		else if self.baseline ~= nil then self.baseline.order else self.scheduler:GetNextRecordOrder(self.key)

	return if self.stagedOrder ~= nil then math.min(order or math.huge, self.stagedOrder) else order
end

function ActorRecipientStream.HasWorkThrough(self: Stream, order: number): boolean
	local nextOrder = self:GetNextOrder()

	return nextOrder ~= nil and nextOrder <= order
end

function ActorRecipientStream.Destroy(self: Stream): ()
	self:ResetRecovery()
	self:_clearBaseline()
	-- Only the pump epilogue releases staged ownership, including reentrant teardown.
	self.scheduler:Destroy()
end

return ActorRecipientStream
