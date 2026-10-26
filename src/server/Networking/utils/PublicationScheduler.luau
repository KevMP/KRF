--!strict
local Types = require(script.Parent.Parent.types)
local SharedTypes = require(script.Parent.Parent.Parent.Parent.shared.Networking.types)
local Composition = require(script.Parent.PublicationPatchComposition)
local Metrics = require(script.Parent.Parent.Parent.Parent.shared.Networking.utils.NetworkingMetrics)

local PublicationScheduler = {}
PublicationScheduler.__index = PublicationScheduler

type Pending = {
	queuedAt: number,
	commit: Types.PublicationFilteredCommit,
	bytes: number,
	order: number,
	charge: Types.PublicationCharge?,
}

type Stream = {
	key: Types.PublicationStreamKey,
	records: { Pending },
	needsBaseline: boolean,
	pendingEvents: number,
	queuedBytes: number,
	barriers: number,
	delivered: { [string]: Types.PublicationDomainTruth },
	active: boolean,
}

type RuntimeState = {
	options: Types.PublicationSchedulerOptions,
	streams: { [any]: { [any]: Stream } },
	active: { Stream },
}

type Runtime = typeof(setmetatable({} :: RuntimeState, PublicationScheduler))

local function diagnosticOwner(self: Runtime): SharedTypes.DiagnosticCollector?
	local owner = self.options.diagnostics

	return if owner ~= nil and (self.options.IsCurrent == nil or self.options.IsCurrent()) then owner else nil
end

local function abandon(self: Runtime, stream: Stream): ()
	local owner = diagnosticOwner(self)
	Metrics.Count(owner, "publicationRecordsAbandoned", #stream.records)
	Metrics.Adjust(owner, "publicationQueuedRecords", -#stream.records)
	Metrics.Adjust(owner, "publicationQueuedBytes", -stream.queuedBytes)
end

local function truthBeforeTail(stream: Stream): { [string]: Types.PublicationDomainTruth }
	local truth: { [string]: Types.PublicationDomainTruth } = table.clone(stream.delivered)

	for index = 1, #stream.records - 1 do
		for _, item in stream.records[index].commit.patches do
			Composition.ApplyKnown(truth, item.domainId, item.patch)
		end
	end

	return truth
end

local function find(self: Runtime, key: Types.PublicationStreamKey, create: boolean): Stream?
	local actors: { [any]: Stream } = self.streams[key.recipient]

	if actors == nil then
		if not create then
			return nil
		end

		actors = {}
		self.streams[key.recipient] = actors
	end

	local stream: Stream? = actors[key.actor]

	if stream == nil and create then
		local created: Stream = {
			key = { recipient = key.recipient, actor = key.actor },
			records = {},
			needsBaseline = false,
			pendingEvents = 0,
			queuedBytes = 0,
			barriers = 0,
			delivered = {},
			active = false,
		}

		actors[key.actor] = created
		stream = created
	end

	return stream
end

local function deactivate(self: Runtime, stream: Stream): ()
	if not stream.active then
		return
	end

	stream.active = false

	for index, active in self.active do
		if active == stream then
			table.remove(self.active, index)
			break
		end
	end
end

local function activate(self: Runtime, stream: Stream): ()
	if stream.active or #stream.records == 0 then
		return
	end

	stream.active = true
	table.insert(self.active, stream)
end

function PublicationScheduler.new(options: Types.PublicationSchedulerOptions): Types.PublicationScheduler
	local state: RuntimeState = { options = options, streams = {}, active = {} }
	local runtime: Runtime = setmetatable(state, PublicationScheduler)

	return runtime :: Types.PublicationScheduler
end

function PublicationScheduler.Enqueue(
	self: Runtime,
	key: Types.PublicationStreamKey,
	commit: Types.PublicationFilteredCommit,
	order: number?
): (boolean, string?)
	local stream: Stream = find(self, key, true) :: Stream

	if stream.needsBaseline then
		Metrics.Count(diagnosticOwner(self), "publicationDropped", 1)

		return false, "PublicationBaselinePending"
	end

	local records = stream.records
	local tail = records[#records]
	local isEvent = #commit.events > 0
	local canMerge = tail ~= nil and #tail.commit.events == 0 and tail.order == (order or 0)
	local composed = if canMerge then Composition.Combine(tail.commit, commit, truthBeforeTail(stream)) else commit
	local newRecords = #records + (if canMerge or (#composed.patches == 0 and not isEvent) then 0 else 1)
	local size = if #composed.patches == 0 and #composed.events == 0 then 0 else self.options.MeasureRecord(composed)
	local newBytes = stream.queuedBytes - (if canMerge then tail.bytes else 0) + size
	local barriers = stream.barriers + (if isEvent then 1 else 0)

	if
		newRecords > self.options.maxBarriers + 1
		or barriers > self.options.maxBarriers
		or stream.pendingEvents + #commit.events > self.options.maxEvents
		or newBytes > self.options.maxQueuedBytes
		or (
			self.options.backlog ~= nil
			and (newRecords > self.options.backlog.maxStreamRecords or newBytes > self.options.backlog.maxStreamBytes)
		)
	then
		Metrics.Count(diagnosticOwner(self), "streamDiscontinuities", 1)
		Metrics.Count(diagnosticOwner(self), "publicationDropped", 1)
		self:MarkBaselinePending(key)

		return false, "PublicationStreamOverloaded"
	end

	-- Capacity replacement is atomic: retain the old tail unless the new one fits.
	local charge: Types.PublicationCharge? = nil

	if size > 0 and self.options.backlog ~= nil then
		charge = self.options.backlog:Acquire(key, composed, size, if canMerge then tail.charge else nil)

		if charge == nil then
			Metrics.Count(diagnosticOwner(self), "streamDiscontinuities", 1)
			Metrics.Count(diagnosticOwner(self), "publicationDropped", 1)
			self:MarkBaselinePending(key)

			return false, "PublicationAggregateOverloaded"
		end
	end

	local owner = diagnosticOwner(self)
	local oldCount, oldBytes = #records, stream.queuedBytes
	local queuedAt = if canMerge then tail.queuedAt else (self.options.Now or os.clock)()

	if canMerge then
		Metrics.Count(owner, "stateCoalesces", 1)

		if size == 0 and tail.charge ~= nil then
			tail.charge.release()
		end

		table.remove(records)
		stream.queuedBytes -= tail.bytes
	end

	if size > 0 then
		table.insert(
			records,
			{ queuedAt = queuedAt, commit = composed, bytes = size, order = order or 0, charge = charge }
		)

		stream.queuedBytes += size
		stream.pendingEvents += #composed.events
		stream.barriers += if #composed.events > 0 then 1 else 0
	end

	Metrics.Count(owner, "publicationAdmitted", 1)
	Metrics.Count(owner, "semanticBarriers", if isEvent then 1 else 0)
	Metrics.Adjust(owner, "publicationQueuedRecords", #records - oldCount)
	Metrics.Adjust(owner, "publicationQueuedBytes", stream.queuedBytes - oldBytes)
	activate(self, stream)

	if #records == 0 then
		deactivate(self, stream)
	end

	return true, nil
end

function PublicationScheduler.MarkBaselinePending(self: Runtime, key: Types.PublicationStreamKey): ()
	local stream: Stream = find(self, key, true) :: Stream
	abandon(self, stream)

	for _, pending in stream.records do
		if pending.charge ~= nil then
			pending.charge.release()
		end
	end

	table.clear(stream.records)
	stream.pendingEvents = 0
	stream.queuedBytes = 0
	stream.barriers = 0
	stream.needsBaseline = true
	stream.delivered = {}
	deactivate(self, stream)
end

function PublicationScheduler.ResetAfterBaseline(
	self: Runtime,
	key: Types.PublicationStreamKey,
	domains: { [string]: Types.PublicationDomainTruth },
	preserveQueued: boolean?,
	owned: boolean?
): ()
	local stream: Stream = find(self, key, true) :: Stream

	if not preserveQueued then
		abandon(self, stream)

		for _, pending in stream.records do
			if pending.charge ~= nil then
				pending.charge.release()
			end
		end

		table.clear(stream.records)
		stream.pendingEvents = 0
		stream.queuedBytes = 0
		stream.barriers = 0
		deactivate(self, stream)
	end

	stream.needsBaseline = false
	-- N3 canonical values are already frozen and owned; applying a patch copies
	-- changed paths. Only the top-level delivered index must be writable here.
	stream.delivered = if owned then table.clone(domains) else Composition.Copy(domains)
end

function PublicationScheduler.RemoveStream(self: Runtime, key: Types.PublicationStreamKey): ()
	local stream: Stream? = find(self, key, false)

	if stream == nil then
		return
	end

	deactivate(self, stream)
	abandon(self, stream)

	for _, pending in stream.records do
		if pending.charge ~= nil then
			pending.charge.release()
		end
	end

	local actors = self.streams[key.recipient]
	actors[key.actor] = nil

	if next(actors) == nil then
		self.streams[key.recipient] = nil
	end
end

function PublicationScheduler.GetStreamStatus(
	self: Runtime,
	key: Types.PublicationStreamKey
): Types.PublicationStreamStatus
	local stream: Stream? = find(self, key, false)

	if stream == nil then
		return { needsBaseline = false, pendingRecords = 0, pendingEvents = 0, queuedBytes = 0 }
	end

	return {
		needsBaseline = stream.needsBaseline,
		pendingRecords = #stream.records,
		pendingEvents = stream.pendingEvents,
		queuedBytes = stream.queuedBytes,
	}
end

function PublicationScheduler.GetNextRecordBytes(self: Runtime, key: Types.PublicationStreamKey): number?
	local stream: Stream? = find(self, key, false)
	local pending: Pending? = if stream ~= nil then stream.records[1] else nil

	return if pending ~= nil then pending.bytes else nil
end

function PublicationScheduler.GetNextRecordOrder(self: Runtime, key: Types.PublicationStreamKey): number?
	local stream: Stream? = find(self, key, false)
	local pending: Pending? = if stream ~= nil then stream.records[1] else nil

	return if pending ~= nil then pending.order else nil
end

function PublicationScheduler.GetNextRecordQueuedAt(self: Runtime, key: Types.PublicationStreamKey): number?
	local stream = find(self, key, false)
	local pending = if stream ~= nil then stream.records[1] else nil

	return if pending ~= nil then pending.queuedAt else nil
end

function PublicationScheduler.DrainBudgeted(
	self: Runtime,
	maxBytes: number,
	maxRecords: number
): Types.PublicationDrainResult
	local records: { Types.PublicationRecord } = {}
	local encodedBytes = 0
	local visitedStreams = 0

	if maxBytes <= 0 or maxRecords <= 0 then
		return { records = records, encodedBytes = 0, visitedStreams = 0 }
	end

	local remainingVisits = #self.active

	while #self.active > 0 and remainingVisits > 0 and #records < maxRecords do
		local stream: Stream = self.active[1]
		table.remove(self.active, 1)
		stream.active = false
		visitedStreams += 1
		remainingVisits -= 1
		local pending = stream.records[1]

		if pending ~= nil and encodedBytes + pending.bytes <= maxBytes then
			table.remove(stream.records, 1)
			local owner = diagnosticOwner(self)
			Metrics.Adjust(owner, "publicationQueuedRecords", -1)
			Metrics.Adjust(owner, "publicationQueuedBytes", -pending.bytes)

			Metrics.Observe(
				owner,
				"reliableQueueResidenceSeconds",
				math.max(0, (self.options.Now or os.clock)() - pending.queuedAt)
			)

			stream.pendingEvents -= #pending.commit.events
			stream.queuedBytes -= pending.bytes
			stream.barriers -= if #pending.commit.events > 0 then 1 else 0

			local charge = pending.charge

			if charge ~= nil then
				if self.options.retainDrained then
					charge.stage()
				else
					charge.release()
					charge = nil
				end
			end

			table.insert(
				records,
				{ stream = stream.key, commit = pending.commit, encodedSizeBytes = pending.bytes, charge = charge }
			)

			encodedBytes += pending.bytes

			for _, item in pending.commit.patches do
				Composition.ApplyKnown(stream.delivered, item.domainId, item.patch)
			end

			if #stream.records > 0 then
				remainingVisits += 1
			end
		end

		activate(self, stream)
	end

	return { records = records, encodedBytes = encodedBytes, visitedStreams = visitedStreams }
end

function PublicationScheduler.Destroy(self: Runtime): ()
	for _, actors in self.streams do
		for _, stream in actors do
			abandon(self, stream)

			for _, pending in stream.records do
				if pending.charge ~= nil then
					pending.charge.release()
				end
			end
		end
	end

	table.clear(self.active)
	table.clear(self.streams)
end

return PublicationScheduler
