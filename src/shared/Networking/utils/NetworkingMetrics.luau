--!strict
local Types = require(script.Parent.Parent.types)
local Metrics = {}

function Metrics.new(scope: Types.DiagnosticScope, parent: Types.DiagnosticCollector?): Types.DiagnosticCollector
	local counters: { [Types.DiagnosticCounter]: number } = {
		reliableSendAttempts = 0,
		reliableEncodedBytes = 0,
		reliableLogicalRecords = 0,
		unreliableSendAttempts = 0,
		unreliableEncodedBytes = 0,
		unreliableLogicalRecords = 0,
		commandsAdmitted = 0,
		commandsRefused = 0,
		hintRecordsAdmitted = 0,
		hintRecordsRefused = 0,
		hintPacketsAdmitted = 0,
		hintPacketsRefused = 0,
		reliableChargesAdmitted = 0,
		reliableChargesRefused = 0,
		publicationAdmitted = 0,
		publicationDropped = 0,
		stateCoalesces = 0,
		semanticBarriers = 0,
		streamDiscontinuities = 0,
		baselinesCaptured = 0,
		baselinesCompleted = 0,
		baselinesRestarted = 0,
		baselinesAbandoned = 0,
		recoveryBackoffs = 0,
		recoveryAbandoned = 0,
		resyncRequests = 0,
		resyncAdmitted = 0,
		resyncDeduplicated = 0,
		resyncRateLimited = 0,
		resyncRefused = 0,
		commandsAbandoned = 0,
		commandsReceived = 0,
		commandsDispatched = 0,
		commandsExecuted = 0,
		commandsAccepted = 0,
		commandsRejected = 0,
		commandsRateLimited = 0,
		commandsFaulted = 0,
		commandsUncertain = 0,
		commandResultsExpired = 0,
		commandReservationsAdmitted = 0,
		commandReservationsRefused = 0,
		hintsSent = 0,
		hintsReceived = 0,
		hintsCoalesced = 0,
		hintsDropped = 0,
		hintsStaleDropped = 0,
		hintsMalformed = 0,
		hintsUnauthorized = 0,
		hintPacketsDropped = 0,
		hintCallbackFaults = 0,
		hintSendFailures = 0,
		reliableConnectionVisits = 0,
		reliableStreamVisits = 0,
		reliableChecks = 0,
		reliablePrepares = 0,
		reliableMeasurements = 0,
		reliableEncodes = 0,
		reliableCaptures = 0,
		reliablePriorityVisits = 0,
		reliableUnproductiveInspections = 0,
		commandConnectionVisits = 0,
		commandUnproductiveInspections = 0,
		hintConnectionVisits = 0,
		hintSendVisits = 0,
		hintReceiveVisits = 0,
		hintUnproductiveInspections = 0,
		publicationRecordsAbandoned = 0,
		baselineCapacityRefusals = 0,
		commandResultsReceived = 0,
		clientReliableDeferredAdmitted = 0,
		clientReliableDeferredDropped = 0,
	}

	local gauges: { [Types.DiagnosticGauge]: { current: number, highWater: number } } = {
		connections = { current = 0, highWater = 0 },
		reliableRecords = { current = 0, highWater = 0 },
		reliableRetainedBytes = { current = 0, highWater = 0 },
		reliableDeliveryBytes = { current = 0, highWater = 0 },
		commandRequests = { current = 0, highWater = 0 },
		commandBytes = { current = 0, highWater = 0 },
		hintSendRecords = { current = 0, highWater = 0 },
		hintSendBytes = { current = 0, highWater = 0 },
		hintReceivePackets = { current = 0, highWater = 0 },
		hintReceiveBytes = { current = 0, highWater = 0 },
		readyConnections = { current = 0, highWater = 0 },
		awareStreams = { current = 0, highWater = 0 },
		reliableActiveConnections = { current = 0, highWater = 0 },
		reliableActiveStreams = { current = 0, highWater = 0 },
		baselineGenerations = { current = 0, highWater = 0 },
		recoveryStreams = { current = 0, highWater = 0 },
		commandResultSlots = { current = 0, highWater = 0 },
		commandResultReservedBytes = { current = 0, highWater = 0 },
		commandFencedRecords = { current = 0, highWater = 0 },
		commandFencedBytes = { current = 0, highWater = 0 },
		commandHistoryEntries = { current = 0, highWater = 0 },
		commandHistoryBytes = { current = 0, highWater = 0 },
		clientCommandPending = { current = 0, highWater = 0 },
		clientCommandMetadataBytes = { current = 0, highWater = 0 },
		clientBaselineAssemblies = { current = 0, highWater = 0 },
		clientBaselineBytes = { current = 0, highWater = 0 },
		hintLatestKeys = { current = 0, highWater = 0 },
		publicationQueuedRecords = { current = 0, highWater = 0 },
		publicationQueuedBytes = { current = 0, highWater = 0 },
		clientReliableDeferredRecords = { current = 0, highWater = 0 },
		clientReliableDeferredBytes = { current = 0, highWater = 0 },
	}

	local maxima: { [Types.DiagnosticMaximum]: number } = {
		reliablePumpWorkUnits = 0,
		commandPumpWorkUnits = 0,
		hintSendPumpWorkUnits = 0,
		hintReceivePumpWorkUnits = 0,
		commandQueueResidenceSeconds = 0,
		reliableQueueResidenceSeconds = 0,
		hintSendQueueResidenceSeconds = 0,
		hintReceiveQueueResidenceSeconds = 0,
	}

	local sources: { [Types.DiagnosticAge]: () -> number? } = {}
	local collector: Types.DiagnosticCollector = {} :: Types.DiagnosticCollector

	function collector.Count(_self: Types.DiagnosticCollector, key: Types.DiagnosticCounter, amount: number): ()
		counters[key] = math.min(9007199254740991, counters[key] + amount)

		if parent ~= nil then
			parent:Count(key, amount)
		end
	end

	function collector.Adjust(_self: Types.DiagnosticCollector, key: Types.DiagnosticGauge, delta: number): ()
		local gauge = gauges[key]
		gauge.current += delta
		gauge.highWater = math.max(gauge.highWater, gauge.current)

		if parent ~= nil then
			parent:Adjust(key, delta)
		end
	end

	function collector.Set(_self: Types.DiagnosticCollector, key: Types.DiagnosticGauge, value: number): number
		local previous = gauges[key].current
		collector:Adjust(key, value - previous)

		return previous
	end

	function collector.GetCurrent(_self: Types.DiagnosticCollector, key: Types.DiagnosticGauge): number
		return gauges[key].current
	end

	function collector.Observe(_self: Types.DiagnosticCollector, key: Types.DiagnosticMaximum, value: number): ()
		maxima[key] = math.max(maxima[key], value)

		if parent ~= nil then
			parent:Observe(key, value)
		end
	end

	function collector.SetAgeSource(
		_self: Types.DiagnosticCollector,
		key: Types.DiagnosticAge,
		source: (() -> number?)?
	): ()
		sources[key] = source
	end

	function collector.GetAge(_self: Types.DiagnosticCollector, key: Types.DiagnosticAge): number?
		local source = sources[key]

		return if source ~= nil then source() else nil
	end

	function collector.ClearSources(_self: Types.DiagnosticCollector): ()
		table.clear(sources)
	end

	function collector.Snapshot(_self: Types.DiagnosticCollector): Types.DiagnosticSnapshot
		local values: { [Types.DiagnosticGauge]: Types.DiagnosticGaugeSnapshot } = {}

		for key, gauge in gauges do
			values[key] = table.freeze({ current = gauge.current, highWater = gauge.highWater })
		end

		return table.freeze({
			scope = scope,
			counters = table.freeze({
				reliableSendAttempts = counters.reliableSendAttempts,
				reliableEncodedBytes = counters.reliableEncodedBytes,
				reliableLogicalRecords = counters.reliableLogicalRecords,
				unreliableSendAttempts = counters.unreliableSendAttempts,
				unreliableEncodedBytes = counters.unreliableEncodedBytes,
				unreliableLogicalRecords = counters.unreliableLogicalRecords,
				commandsAdmitted = counters.commandsAdmitted,
				commandsRefused = counters.commandsRefused,
				hintRecordsAdmitted = counters.hintRecordsAdmitted,
				hintRecordsRefused = counters.hintRecordsRefused,
				hintPacketsAdmitted = counters.hintPacketsAdmitted,
				hintPacketsRefused = counters.hintPacketsRefused,
				reliableChargesAdmitted = counters.reliableChargesAdmitted,
				reliableChargesRefused = counters.reliableChargesRefused,
				publicationAdmitted = counters.publicationAdmitted,
				publicationDropped = counters.publicationDropped,
				stateCoalesces = counters.stateCoalesces,
				semanticBarriers = counters.semanticBarriers,
				streamDiscontinuities = counters.streamDiscontinuities,
				baselinesCaptured = counters.baselinesCaptured,
				baselinesCompleted = counters.baselinesCompleted,
				baselinesRestarted = counters.baselinesRestarted,
				baselinesAbandoned = counters.baselinesAbandoned,
				recoveryBackoffs = counters.recoveryBackoffs,
				recoveryAbandoned = counters.recoveryAbandoned,
				resyncRequests = counters.resyncRequests,
				resyncAdmitted = counters.resyncAdmitted,
				resyncDeduplicated = counters.resyncDeduplicated,
				resyncRateLimited = counters.resyncRateLimited,
				resyncRefused = counters.resyncRefused,
				commandsAbandoned = counters.commandsAbandoned,
				commandsReceived = counters.commandsReceived,
				commandsDispatched = counters.commandsDispatched,
				commandsExecuted = counters.commandsExecuted,
				commandsAccepted = counters.commandsAccepted,
				commandsRejected = counters.commandsRejected,
				commandsRateLimited = counters.commandsRateLimited,
				commandsFaulted = counters.commandsFaulted,
				commandsUncertain = counters.commandsUncertain,
				commandResultsExpired = counters.commandResultsExpired,
				commandReservationsAdmitted = counters.commandReservationsAdmitted,
				commandReservationsRefused = counters.commandReservationsRefused,
				hintsSent = counters.hintsSent,
				hintsReceived = counters.hintsReceived,
				hintsCoalesced = counters.hintsCoalesced,
				hintsDropped = counters.hintsDropped,
				hintsStaleDropped = counters.hintsStaleDropped,
				hintsMalformed = counters.hintsMalformed,
				hintsUnauthorized = counters.hintsUnauthorized,
				hintPacketsDropped = counters.hintPacketsDropped,
				hintCallbackFaults = counters.hintCallbackFaults,
				hintSendFailures = counters.hintSendFailures,
				reliableConnectionVisits = counters.reliableConnectionVisits,
				reliableStreamVisits = counters.reliableStreamVisits,
				reliableChecks = counters.reliableChecks,
				reliablePrepares = counters.reliablePrepares,
				reliableMeasurements = counters.reliableMeasurements,
				reliableEncodes = counters.reliableEncodes,
				reliableCaptures = counters.reliableCaptures,
				reliablePriorityVisits = counters.reliablePriorityVisits,
				reliableUnproductiveInspections = counters.reliableUnproductiveInspections,
				commandConnectionVisits = counters.commandConnectionVisits,
				commandUnproductiveInspections = counters.commandUnproductiveInspections,
				hintConnectionVisits = counters.hintConnectionVisits,
				hintSendVisits = counters.hintSendVisits,
				hintReceiveVisits = counters.hintReceiveVisits,
				hintUnproductiveInspections = counters.hintUnproductiveInspections,
				publicationRecordsAbandoned = counters.publicationRecordsAbandoned,
				baselineCapacityRefusals = counters.baselineCapacityRefusals,
				commandResultsReceived = counters.commandResultsReceived,
				clientReliableDeferredAdmitted = counters.clientReliableDeferredAdmitted,
				clientReliableDeferredDropped = counters.clientReliableDeferredDropped,
			}),
			maxima = table.freeze({
				reliablePumpWorkUnits = maxima.reliablePumpWorkUnits,
				commandPumpWorkUnits = maxima.commandPumpWorkUnits,
				hintSendPumpWorkUnits = maxima.hintSendPumpWorkUnits,
				hintReceivePumpWorkUnits = maxima.hintReceivePumpWorkUnits,
				commandQueueResidenceSeconds = maxima.commandQueueResidenceSeconds,
				reliableQueueResidenceSeconds = maxima.reliableQueueResidenceSeconds,
				hintSendQueueResidenceSeconds = maxima.hintSendQueueResidenceSeconds,
				hintReceiveQueueResidenceSeconds = maxima.hintReceiveQueueResidenceSeconds,
			}),
			ages = table.freeze({
				reliableEligibleQueueAgeSeconds = collector:GetAge("reliableEligibleQueueAgeSeconds"),
				commandQueueAgeSeconds = collector:GetAge("commandQueueAgeSeconds"),
				hintSendQueueAgeSeconds = collector:GetAge("hintSendQueueAgeSeconds"),
				hintReceiveQueueAgeSeconds = collector:GetAge("hintReceiveQueueAgeSeconds"),
			}),
			gauges = table.freeze({
				connections = values.connections,
				reliableRecords = values.reliableRecords,
				reliableRetainedBytes = values.reliableRetainedBytes,
				reliableDeliveryBytes = values.reliableDeliveryBytes,
				commandRequests = values.commandRequests,
				commandBytes = values.commandBytes,
				hintSendRecords = values.hintSendRecords,
				hintSendBytes = values.hintSendBytes,
				hintReceivePackets = values.hintReceivePackets,
				hintReceiveBytes = values.hintReceiveBytes,
				readyConnections = values.readyConnections,
				awareStreams = values.awareStreams,
				reliableActiveConnections = values.reliableActiveConnections,
				reliableActiveStreams = values.reliableActiveStreams,
				baselineGenerations = values.baselineGenerations,
				recoveryStreams = values.recoveryStreams,
				commandResultSlots = values.commandResultSlots,
				commandResultReservedBytes = values.commandResultReservedBytes,
				commandFencedRecords = values.commandFencedRecords,
				commandFencedBytes = values.commandFencedBytes,
				commandHistoryEntries = values.commandHistoryEntries,
				commandHistoryBytes = values.commandHistoryBytes,
				clientCommandPending = values.clientCommandPending,
				clientCommandMetadataBytes = values.clientCommandMetadataBytes,
				clientBaselineAssemblies = values.clientBaselineAssemblies,
				clientBaselineBytes = values.clientBaselineBytes,
				hintLatestKeys = values.hintLatestKeys,
				publicationQueuedRecords = values.publicationQueuedRecords,
				publicationQueuedBytes = values.publicationQueuedBytes,
				clientReliableDeferredRecords = values.clientReliableDeferredRecords,
				clientReliableDeferredBytes = values.clientReliableDeferredBytes,
			}),
		})
	end

	return collector
end

function Metrics.Count(collector: Types.DiagnosticCollector?, key: Types.DiagnosticCounter, amount: number): ()
	if collector ~= nil then
		collector:Count(key, amount)
	end
end

function Metrics.Adjust(collector: Types.DiagnosticCollector?, key: Types.DiagnosticGauge, delta: number): ()
	if collector ~= nil then
		collector:Adjust(key, delta)
	end
end

function Metrics.Observe(collector: Types.DiagnosticCollector?, key: Types.DiagnosticMaximum, value: number): ()
	if collector ~= nil then
		collector:Observe(key, value)
	end
end

function Metrics.Set(collector: Types.DiagnosticCollector?, key: Types.DiagnosticGauge, value: number): number
	return if collector ~= nil then collector:Set(key, value) else 0
end

return Metrics
