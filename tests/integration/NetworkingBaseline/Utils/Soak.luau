--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage.Packages.KRF.shared.Networking.types)
local Constants = require(ReplicatedStorage.Packages.KRF.shared.Networking.utils.ActorProtocolConstants)
local Soak = {}

local function gauges(snapshot: Types.DiagnosticSnapshot): { [string]: Types.DiagnosticGaugeSnapshot }
	return {
		connections = snapshot.gauges.connections,
		readyConnections = snapshot.gauges.readyConnections,
		awareStreams = snapshot.gauges.awareStreams,
		reliableRecords = snapshot.gauges.reliableRecords,
		reliableRetainedBytes = snapshot.gauges.reliableRetainedBytes,
		reliableDeliveryBytes = snapshot.gauges.reliableDeliveryBytes,
		reliableActiveConnections = snapshot.gauges.reliableActiveConnections,
		reliableActiveStreams = snapshot.gauges.reliableActiveStreams,
		baselineGenerations = snapshot.gauges.baselineGenerations,
		recoveryStreams = snapshot.gauges.recoveryStreams,
		publicationQueuedRecords = snapshot.gauges.publicationQueuedRecords,
		publicationQueuedBytes = snapshot.gauges.publicationQueuedBytes,
		commandRequests = snapshot.gauges.commandRequests,
		commandBytes = snapshot.gauges.commandBytes,
		commandResultSlots = snapshot.gauges.commandResultSlots,
		commandResultReservedBytes = snapshot.gauges.commandResultReservedBytes,
		commandFencedRecords = snapshot.gauges.commandFencedRecords,
		commandFencedBytes = snapshot.gauges.commandFencedBytes,
		commandHistoryEntries = snapshot.gauges.commandHistoryEntries,
		commandHistoryBytes = snapshot.gauges.commandHistoryBytes,
		clientCommandPending = snapshot.gauges.clientCommandPending,
		clientCommandMetadataBytes = snapshot.gauges.clientCommandMetadataBytes,
		clientBaselineAssemblies = snapshot.gauges.clientBaselineAssemblies,
		clientBaselineBytes = snapshot.gauges.clientBaselineBytes,
		clientReliableDeferredRecords = snapshot.gauges.clientReliableDeferredRecords,
		clientReliableDeferredBytes = snapshot.gauges.clientReliableDeferredBytes,
		hintSendRecords = snapshot.gauges.hintSendRecords,
		hintSendBytes = snapshot.gauges.hintSendBytes,
		hintReceivePackets = snapshot.gauges.hintReceivePackets,
		hintReceiveBytes = snapshot.gauges.hintReceiveBytes,
		hintLatestKeys = snapshot.gauges.hintLatestKeys,
	}
end

-- Scalars only: snapshots never contain Actor/View identities or queue payloads.
function Soak.read(owner: Types.DiagnosticCollector): any
	local snapshot = owner:Snapshot()
	assert(snapshot.gauges.reliableRecords.highWater <= Constants.BACKLOG_RECORDS, "Record bound exceeded")
	assert(snapshot.gauges.reliableRetainedBytes.highWater <= Constants.BACKLOG_BYTES, "Byte bound exceeded")

	local ownership, highWater = {}, {}

	for key, gauge in gauges(snapshot) do
		ownership[key], highWater[key] = gauge.current, gauge.highWater
	end

	local counters = snapshot.counters

	return {
		heapKiB = gcinfo(),
		unixMs = DateTime.now().UnixTimestampMillis,
		ownership = ownership,
		highWater = highWater,
		counters = {
			sends = counters.reliableSendAttempts,
			encodedBytes = counters.reliableEncodedBytes,
			logicalRecords = counters.reliableLogicalRecords,
			dropped = counters.publicationDropped,
			discontinuities = counters.streamDiscontinuities,
			captured = counters.baselinesCaptured,
			completed = counters.baselinesCompleted,
			restarted = counters.baselinesRestarted,
			abandoned = counters.baselinesAbandoned,
			backoffs = counters.recoveryBackoffs,
			recoveryAbandoned = counters.recoveryAbandoned,
			resyncRequests = counters.resyncRequests,
			hintSendFailures = counters.hintSendFailures,
		},
	}
end

function Soak.assertDrained(snapshot: Types.DiagnosticSnapshot, destroyed: boolean): ()
	for key, gauge in gauges(snapshot) do
		if destroyed or (key ~= "connections" and key ~= "readyConnections" and key ~= "awareStreams") then
			assert(gauge.current == 0, "Retained ownership: " .. key .. "=" .. gauge.current)
		end
	end
end

-- Fixed 16-bin histogram, rather than a growing per-frame sample history.
function Soak.histogram(): any
	return { bins = table.create(16, 0), count = 0, maximumUs = 0 }
end

function Soak.observe(histogram: any, microseconds: number): ()
	local bin = math.clamp(math.ceil(math.log(math.max(1, microseconds)) / math.log(2)) + 1, 1, 16)

	histogram.bins[bin] += 1
	histogram.count += 1
	histogram.maximumUs = math.max(histogram.maximumUs, microseconds)
end

function Soak.summarize(histogram: any): any
	local cumulative = 0
	local upper = 0

	for index, count in histogram.bins do
		cumulative += count

		if cumulative >= histogram.count * 0.95 then
			upper = if index == 16 then histogram.maximumUs else 2 ^ (index - 1)
			break
		end
	end

	return { samples = histogram.count, p95UpperUs = upper, maximumUs = histogram.maximumUs }
end

return Soak
