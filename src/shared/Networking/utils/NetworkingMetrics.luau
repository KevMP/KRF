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
	}

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

return Metrics
