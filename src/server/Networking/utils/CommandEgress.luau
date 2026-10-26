--!strict
local Types = require(script.Parent.Parent.types)
local SharedTypes = require(script.Parent.Parent.Parent.Parent.shared.Networking.types)
local Metrics = require(script.Parent.Parent.Parent.Parent.shared.Networking.utils.NetworkingMetrics)
local Constants = require(script.Parent.Parent.Parent.Parent.shared.Networking.utils.CommandConstants)
local Timer = require(script.Parent.Parent.Parent.Parent.shared.Networking.utils.CommandTimer)

export type Entry = {
	queuedAt: number,
	order: number,
	payload: buffer?,
	reserved: number,
	records: number,
	bytes: number,
	active: boolean,
	cancel: (() -> ())?,
}

export type State = {
	diagnostics: SharedTypes.DiagnosticCollector?,
	now: () -> number,
	order: number,
	queue: { Entry },
	reservedBytes: number,
	fencedBytes: number,
	fencedRecords: number,
	scope: Entry?,
	destroyed: boolean,
	expired: (() -> ())?,
}

local CommandEgress = {}

function CommandEgress.new(
	expired: (() -> ())?,
	diagnostics: SharedTypes.DiagnosticCollector?,
	now: (() -> number)?
): State
	return {
		diagnostics = diagnostics,
		now = now or os.clock,
		order = 0,
		queue = {},
		reservedBytes = 0,
		fencedBytes = 0,
		fencedRecords = 0,
		destroyed = false,
		expired = expired,
	}
end

function CommandEgress.Release(state: State, entry: Entry): ()
	if not entry.active then
		return
	end

	entry.active = false

	if entry.cancel ~= nil then
		entry.cancel()
		entry.cancel = nil
	end

	if state.scope == entry then
		state.scope = nil
	end

	Metrics.Adjust(state.diagnostics, "commandResultSlots", -1)
	Metrics.Adjust(state.diagnostics, "commandResultReservedBytes", -entry.reserved)
	Metrics.Adjust(state.diagnostics, "commandFencedRecords", -entry.records)
	Metrics.Adjust(state.diagnostics, "commandFencedBytes", -entry.bytes)
	Metrics.Observe(state.diagnostics, "reliableQueueResidenceSeconds", math.max(0, state.now() - entry.queuedAt))
	state.reservedBytes -= entry.reserved
	state.fencedBytes -= entry.bytes
	state.fencedRecords -= entry.records

	local index: number? = table.find(state.queue, entry)

	if index ~= nil then
		table.remove(state.queue, index)
	end

	entry.payload = nil
end

function CommandEgress.Reserve(state: State, maxBytes: number): (Types.CommandReservation?, string?)
	if state.destroyed or state.scope ~= nil then
		Metrics.Count(state.diagnostics, "commandReservationsRefused", 1)

		return nil, "CommandEgressUnavailable"
	end

	if maxBytes <= 0 or maxBytes > Constants.MAX_RESULT_BYTES or maxBytes % 1 ~= 0 then
		Metrics.Count(state.diagnostics, "commandReservationsRefused", 1)

		return nil, "InvalidCommandReservation"
	end

	if
		#state.queue >= Constants.MAX_OUTBOUND_RESULTS
		or state.reservedBytes + maxBytes > Constants.MAX_OUTBOUND_BYTES
		or state.order >= Constants.MAX_COUNTER
	then
		Metrics.Count(state.diagnostics, "commandReservationsRefused", 1)

		return nil, "CommandOutboundFull"
	end

	local entry: Entry =
		{ queuedAt = state.now(), order = state.order, reserved = maxBytes, records = 0, bytes = 0, active = true }

	state.order += 1
	state.reservedBytes += maxBytes
	Metrics.Count(state.diagnostics, "commandReservationsAdmitted", 1)
	Metrics.Adjust(state.diagnostics, "commandResultSlots", 1)
	Metrics.Adjust(state.diagnostics, "commandResultReservedBytes", maxBytes)
	state.scope = entry
	table.insert(state.queue, entry)

	entry.cancel = Timer.Schedule(Constants.OUTBOUND_SECONDS, function(): ()
		entry.cancel = nil
		Metrics.Count(state.diagnostics, "commandResultsExpired", 1)
		CommandEgress.Release(state, entry)

		if state.expired ~= nil then
			state.expired()
		end
	end)

	local reservation: Types.CommandReservation = {
		Commit = function(payload: buffer): boolean
			if state.destroyed or not entry.active or entry.payload ~= nil then
				return false
			end

			if buffer.len(payload) > entry.reserved then
				CommandEgress.Release(state, entry)

				return false
			end

			entry.payload = payload

			if state.scope == entry then
				state.scope = nil
			end

			return true
		end,
		Cancel = function(): ()
			CommandEgress.Release(state, entry)
		end,
	}

	return table.freeze(reservation), nil
end

function CommandEgress.AdmitPublication(state: State, bytes: number): boolean
	local scope: Entry? = state.scope

	if scope == nil then
		return true
	end

	if
		state.fencedBytes + bytes > Constants.MAX_FENCED_BYTES
		or state.fencedRecords >= Constants.MAX_FENCED_RECORDS
	then
		return false
	end

	Metrics.Adjust(state.diagnostics, "commandFencedBytes", bytes)
	Metrics.Adjust(state.diagnostics, "commandFencedRecords", 1)
	state.fencedBytes += bytes
	state.fencedRecords += 1
	scope.bytes += bytes
	scope.records += 1

	return true
end

function CommandEgress.Destroy(state: State): ()
	state.destroyed = true

	while #state.queue > 0 do
		CommandEgress.Release(state, state.queue[1])
	end

	state.scope = nil
end

return CommandEgress
