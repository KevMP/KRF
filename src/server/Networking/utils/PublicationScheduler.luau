--!strict
local Types = require(script.Parent.Parent.types)

local PublicationScheduler = {}
PublicationScheduler.__index = PublicationScheduler

type Pending = { commit: Types.PublicationFilteredCommit, bytes: number }

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

local function copy(value: any): any
	if type(value) ~= "table" then
		return value
	end

	local result: { [any]: any } = {}

	for key, item in value do
		result[key] = copy(item)
	end

	return result
end

local function apply(value: any, patch: Types.PublicationPatch): any
	if patch.kind == "Replace" then
		return copy(patch.value)
	end

	-- Delivered subtrees are private. Copy only the path changed by this patch;
	-- incoming replacement values and Map entries still cross an ownership boundary.
	local result = if type(value) == "table" then table.clone(value) else {}

	if patch.kind == "Struct" then
		for field, change in patch.fields do
			result[field] = apply(result[field], change)
		end
	else
		for key, entry in patch.entries do
			result[key] = copy(entry)
		end

		for _, key in patch.removed do
			result[key] = nil
		end
	end

	return result
end

local function merge(
	first: Types.PublicationPatch,
	second: Types.PublicationPatch,
	delivered: Types.PublicationDomainTruth?
): Types.PublicationPatch?
	if second.kind == "Replace" or first.kind ~= second.kind then
		return second
	end

	if first.kind == "Struct" and second.kind == "Struct" then
		local fields: { [string]: Types.PublicationPatch } = table.clone(first.fields)

		for field, change in second.fields do
			local earlier = fields[field]
			local fieldTruth: Types.PublicationDomainTruth? = nil

			if delivered ~= nil and type(delivered.value) == "table" then
				fieldTruth = { value = delivered.value[field] }
			end

			fields[field] = if earlier == nil then change else merge(earlier, change, fieldTruth)
		end

		return { kind = "Struct", fields = fields }
	end

	if first.kind == "Map" and second.kind == "Map" then
		local entries: { [any]: any } = table.clone(first.entries)
		local removals: { [any]: boolean } = {}

		for _, key in first.removed do
			removals[key] = true
		end

		for key, value in second.entries do
			entries[key] = value
			removals[key] = nil
		end

		for _, key in second.removed do
			entries[key] = nil

			if delivered ~= nil and type(delivered.value) == "table" and delivered.value[key] == nil then
				removals[key] = nil
			else
				removals[key] = true
			end
		end

		local removed: { any } = {}

		for key in removals do
			table.insert(removed, key)
		end

		table.sort(removed, function(a: any, b: any): boolean
			return a < b
		end)

		if next(entries) == nil and #removed == 0 then
			return nil
		end

		return { kind = "Map", entries = entries, removed = removed }
	end

	return second
end

local function combine(
	first: Types.PublicationFilteredCommit?,
	second: Types.PublicationFilteredCommit,
	delivered: { [string]: Types.PublicationDomainTruth }
): Types.PublicationFilteredCommit
	if first == nil then
		return second
	end

	local byDomain: { [string]: Types.PublicationPatch } = {}
	local order: { string } = {}

	for _, item in first.patches do
		byDomain[item.domainId] = item.patch
		table.insert(order, item.domainId)
	end

	for _, item in second.patches do
		local previous = byDomain[item.domainId]

		if previous == nil then
			byDomain[item.domainId] = item.patch
			table.insert(order, item.domainId)
		else
			byDomain[item.domainId] = merge(previous, item.patch, delivered[item.domainId])
		end
	end

	local patches: { Types.PublicationDomainPatch } = {}

	for _, domainId in order do
		local patch = byDomain[domainId]

		if patch ~= nil then
			table.insert(patches, { domainId = domainId, patch = patch })
		end
	end

	local events: { Types.PublicationEvent } = {}

	for _, event in first.events do
		table.insert(events, event)
	end

	for _, event in second.events do
		table.insert(events, event)
	end

	return { sequence = second.sequence, patches = patches, events = events }
end

local function applyKnown(
	truth: { [string]: Types.PublicationDomainTruth },
	domainId: string,
	patch: Types.PublicationPatch
): ()
	local previous = truth[domainId]

	if previous ~= nil then
		truth[domainId] = { value = apply(previous.value, patch) }
	elseif patch.kind == "Replace" then
		truth[domainId] = { value = copy(patch.value) }
	end
end

local function truthBeforeTail(stream: Stream): { [string]: Types.PublicationDomainTruth }
	local truth: { [string]: Types.PublicationDomainTruth } = table.clone(stream.delivered)

	for index = 1, #stream.records - 1 do
		for _, item in stream.records[index].commit.patches do
			applyKnown(truth, item.domainId, item.patch)
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
	commit: Types.PublicationFilteredCommit
): (boolean, string?)
	local stream: Stream = find(self, key, true) :: Stream

	if stream.needsBaseline then
		return false, "PublicationBaselinePending"
	end

	local records = stream.records
	local tail = records[#records]
	local isEvent = #commit.events > 0
	local canMerge = tail ~= nil and #tail.commit.events == 0
	local composed = if canMerge then combine(tail.commit, commit, truthBeforeTail(stream)) else commit
	local newRecords = #records + (if canMerge or (#composed.patches == 0 and not isEvent) then 0 else 1)
	local size = if #composed.patches == 0 and #composed.events == 0 then 0 else self.options.MeasureRecord(composed)
	local newBytes = stream.queuedBytes - (if canMerge then tail.bytes else 0) + size
	local barriers = stream.barriers + (if isEvent then 1 else 0)

	if
		newRecords > self.options.maxBarriers + 1
		or barriers > self.options.maxBarriers
		or stream.pendingEvents + #commit.events > self.options.maxEvents
		or newBytes > self.options.maxQueuedBytes
	then
		self:MarkBaselinePending(key)

		return false, "PublicationStreamOverloaded"
	end

	if canMerge then
		table.remove(records)
		stream.queuedBytes -= tail.bytes
	end

	if size > 0 then
		table.insert(records, { commit = composed, bytes = size })
		stream.queuedBytes += size
		stream.pendingEvents += #composed.events
		stream.barriers += if #composed.events > 0 then 1 else 0
	end

	activate(self, stream)

	if #records == 0 then
		deactivate(self, stream)
	end

	return true, nil
end

function PublicationScheduler.MarkBaselinePending(self: Runtime, key: Types.PublicationStreamKey): ()
	local stream: Stream = find(self, key, true) :: Stream
	table.clear(stream.records)
	stream.pendingEvents = 0
	stream.queuedBytes = 0
	stream.barriers = 0
	stream.needsBaseline = true
	deactivate(self, stream)
end

function PublicationScheduler.ResetAfterBaseline(
	self: Runtime,
	key: Types.PublicationStreamKey,
	domains: { [string]: Types.PublicationDomainTruth }
): ()
	local stream: Stream = find(self, key, true) :: Stream
	table.clear(stream.records)
	stream.pendingEvents = 0
	stream.queuedBytes = 0
	stream.barriers = 0
	stream.needsBaseline = false
	stream.delivered = copy(domains)
	deactivate(self, stream)
end

function PublicationScheduler.RemoveStream(self: Runtime, key: Types.PublicationStreamKey): ()
	local stream: Stream? = find(self, key, false)

	if stream == nil then
		return
	end

	deactivate(self, stream)

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
			stream.pendingEvents -= #pending.commit.events
			stream.queuedBytes -= pending.bytes
			stream.barriers -= if #pending.commit.events > 0 then 1 else 0
			table.insert(records, { stream = stream.key, commit = pending.commit, encodedSizeBytes = pending.bytes })
			encodedBytes += pending.bytes

			for _, item in pending.commit.patches do
				applyKnown(stream.delivered, item.domainId, item.patch)
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
	table.clear(self.active)
	table.clear(self.streams)
end

return PublicationScheduler
