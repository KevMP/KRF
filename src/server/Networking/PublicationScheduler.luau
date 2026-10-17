--!strict
local PublicationTypes = require(script.Parent.PublicationTypes)

local PublicationScheduler = {}
PublicationScheduler.__index = PublicationScheduler

type Pending = { commit: PublicationTypes.FilteredCommit, bytes: number }
type Stream = {
	key: PublicationTypes.StreamKey,
	records: { Pending },
	needsBaseline: boolean,
	delivered: { [string]: PublicationTypes.DomainTruth },
	active: boolean,
}

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

local function apply(value: any, patch: PublicationTypes.Patch): any
	if patch.kind == "Replace" then
		return copy(patch.value)
	end
	local result = if type(value) == "table" then copy(value) else {}
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
	first: PublicationTypes.Patch,
	second: PublicationTypes.Patch,
	delivered: PublicationTypes.DomainTruth?
): PublicationTypes.Patch?
	if second.kind == "Replace" or first.kind ~= second.kind then
		return second
	end
	if first.kind == "Struct" and second.kind == "Struct" then
		local fields: { [string]: PublicationTypes.Patch } = table.clone(first.fields)
		for field, change in second.fields do
			local earlier = fields[field]
			local fieldTruth: PublicationTypes.DomainTruth? = nil
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
	first: PublicationTypes.FilteredCommit?,
	second: PublicationTypes.FilteredCommit,
	delivered: { [string]: PublicationTypes.DomainTruth }
): PublicationTypes.FilteredCommit
	if first == nil then
		return second
	end
	local byDomain: { [string]: PublicationTypes.Patch } = {}
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
	local patches: { PublicationTypes.DomainPatch } = {}
	for _, domainId in order do
		local patch = byDomain[domainId]
		if patch ~= nil then
			table.insert(patches, { domainId = domainId, patch = patch })
		end
	end
	local events: { PublicationTypes.Event } = {}
	for _, event in first.events do
		table.insert(events, event)
	end
	for _, event in second.events do
		table.insert(events, event)
	end
	return { sequence = second.sequence, patches = patches, events = events }
end

local function pendingStats(stream: Stream): (number, number)
	local events = 0
	local bytes = 0
	for _, record in stream.records do
		events += #record.commit.events
		bytes += record.bytes
	end
	return events, bytes
end

local function applyKnown(
	truth: { [string]: PublicationTypes.DomainTruth },
	domainId: string,
	patch: PublicationTypes.Patch
): ()
	local previous = truth[domainId]
	if previous ~= nil then
		truth[domainId] = { value = apply(previous.value, patch) }
	elseif patch.kind == "Replace" then
		truth[domainId] = { value = copy(patch.value) }
	end
end

local function truthBeforeTail(stream: Stream): { [string]: PublicationTypes.DomainTruth }
	local truth: { [string]: PublicationTypes.DomainTruth } = copy(stream.delivered)
	for index = 1, #stream.records - 1 do
		for _, item in stream.records[index].commit.patches do
			applyKnown(truth, item.domainId, item.patch)
		end
	end
	return truth
end

local function find(self: any, key: PublicationTypes.StreamKey, create: boolean): Stream?
	local actors = self.streams[key.recipient]
	if actors == nil then
		if not create then
			return nil
		end
		actors = {}
		self.streams[key.recipient] = actors
	end
	local stream = actors[key.actor]
	if stream == nil and create then
		stream = {
			key = { recipient = key.recipient, actor = key.actor },
			records = {},
			needsBaseline = false,
			delivered = {},
			active = false,
		}
		actors[key.actor] = stream
	end
	return stream
end

local function deactivate(self: any, stream: Stream): ()
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

local function activate(self: any, stream: Stream): ()
	if stream.active or #stream.records == 0 then
		return
	end
	stream.active = true
	table.insert(self.active, stream)
end

function PublicationScheduler.new(options: PublicationTypes.SchedulerOptions): PublicationTypes.Scheduler
	return setmetatable({ options = options, streams = {}, active = {} }, PublicationScheduler) :: any
end

function PublicationScheduler.Enqueue(
	self: any,
	key: PublicationTypes.StreamKey,
	commit: PublicationTypes.FilteredCommit
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
	local events, bytes = pendingStats(stream)
	local size = if #composed.patches == 0 and #composed.events == 0 then 0 else self.options.MeasureRecord(composed)
	local newBytes = bytes - (if canMerge then tail.bytes else 0) + size
	local barriers = 0
	for _, record in records do
		if #record.commit.events > 0 then
			barriers += 1
		end
	end
	if isEvent then
		barriers += 1
	end
	if
		newRecords > self.options.maxBarriers + 1
		or barriers > self.options.maxBarriers
		or events + #commit.events > self.options.maxEvents
		or newBytes > self.options.maxQueuedBytes
	then
		self:MarkBaselinePending(key)
		return false, "PublicationStreamOverloaded"
	end
	if canMerge then
		table.remove(records)
	end
	if size > 0 then
		table.insert(records, { commit = composed, bytes = size })
	end
	activate(self, stream)
	if #records == 0 then
		deactivate(self, stream)
	end
	return true, nil
end

function PublicationScheduler.MarkBaselinePending(self: any, key: PublicationTypes.StreamKey): ()
	local stream: Stream = find(self, key, true) :: Stream
	table.clear(stream.records)
	stream.needsBaseline = true
	deactivate(self, stream)
end

function PublicationScheduler.ResetAfterBaseline(
	self: any,
	key: PublicationTypes.StreamKey,
	domains: { [string]: PublicationTypes.DomainTruth }
): ()
	local stream: Stream = find(self, key, true) :: Stream
	table.clear(stream.records)
	stream.needsBaseline = false
	stream.delivered = copy(domains)
	deactivate(self, stream)
end

function PublicationScheduler.RemoveStream(self: any, key: PublicationTypes.StreamKey): ()
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

function PublicationScheduler.GetStreamStatus(self: any, key: PublicationTypes.StreamKey): PublicationTypes.StreamStatus
	local stream: Stream? = find(self, key, false)
	if stream == nil then
		return { needsBaseline = false, pendingRecords = 0, pendingEvents = 0, queuedBytes = 0 }
	end
	local events, bytes = pendingStats(stream)
	return {
		needsBaseline = stream.needsBaseline,
		pendingRecords = #stream.records,
		pendingEvents = events,
		queuedBytes = bytes,
	}
end

function PublicationScheduler.GetNextRecordBytes(self: any, key: PublicationTypes.StreamKey): number?
	local stream: Stream? = find(self, key, false)
	local pending: Pending? = if stream ~= nil then stream.records[1] else nil
	return if pending ~= nil then pending.bytes else nil
end

function PublicationScheduler.DrainBudgeted(
	self: any,
	maxBytes: number,
	maxRecords: number
): PublicationTypes.DrainResult
	local records: { PublicationTypes.Record } = {}
	local encodedBytes = 0
	local visitedStreams = 0
	if maxBytes <= 0 or maxRecords <= 0 then
		return { records = records, encodedBytes = 0, visitedStreams = 0 }
	end
	local remainingVisits = #self.active
	while #self.active > 0 and remainingVisits > 0 and #records < maxRecords do
		local stream: Stream = table.remove(self.active, 1)
		stream.active = false
		visitedStreams += 1
		remainingVisits -= 1
		local pending = stream.records[1]
		if pending ~= nil and encodedBytes + pending.bytes <= maxBytes then
			table.remove(stream.records, 1)
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

function PublicationScheduler.Destroy(self: any): ()
	table.clear(self.active)
	table.clear(self.streams)
end

return PublicationScheduler
