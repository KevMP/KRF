--!strict
local Types = require(script.Parent.Parent.types)
local Constants = require(script.Parent.HintConstants)
local Metrics = require(script.Parent.NetworkingMetrics)

export type Pool = { pendingCount: number, pendingBytes: number, latestCount: number }
export type Latest<T> = { sequence: number, actor: T?, job: Job<T>? }
export type Job<T> = { queuedAt: number, bytes: buffer, actor: T?, handle: number?, latest: Latest<T>? }

export type State<T> = {
	queue: { Job<T> },
	latest: { [string]: Latest<T> },
	pendingCount: number,
	pendingBytes: number,
	latestCount: number,
	pool: Pool,
	diagnostics: Types.DiagnosticCollector?,
	now: () -> number,
}

export type Batch<T> = { jobs: { Job<T> }, records: { buffer }, bytes: number, work: number }

local Outbox = {}

function Outbox.pool(): Pool
	return { pendingCount = 0, pendingBytes = 0, latestCount = 0 }
end

function Outbox.new<T>(pool: Pool, diagnostics: Types.DiagnosticCollector?, now: () -> number): State<T>
	return {
		queue = {},
		latest = {},
		pendingCount = 0,
		pendingBytes = 0,
		latestCount = 0,
		pool = pool,
		diagnostics = diagnostics,
		now = now,
	}
end

-- Admission limits belong to the lane owner. Mutation of queue/key/byte ownership
-- is atomic here, after validation and encoding, without callbacks or a second FIFO.
function Outbox.Admit<T>(
	state: State<T>,
	key: string,
	actor: T?,
	handle: number?,
	encoded: buffer,
	sequence: number?,
	now: number
): ()
	local latest = if sequence ~= nil then state.latest[key] else nil
	local previous = if latest ~= nil then latest.job else nil
	local bytes = buffer.len(encoded)
	local delta = bytes - (if previous ~= nil then buffer.len(previous.bytes) else 0)

	if sequence ~= nil then
		if latest == nil then
			local created: Latest<T> = { sequence = sequence, actor = actor }
			latest = created
			state.latest[key] = latest
			state.latestCount += 1
			state.pool.latestCount += 1
			Metrics.Adjust(state.diagnostics, "hintLatestKeys", 1)
		else
			latest.sequence = sequence
		end
	end

	state.pendingBytes += delta
	state.pool.pendingBytes += delta
	Metrics.Adjust(state.diagnostics, "hintSendBytes", delta)

	if previous ~= nil then
		previous.bytes, previous.queuedAt = encoded, now
		Metrics.Count(state.diagnostics, "hintsCoalesced", 1)
	else
		local job: Job<T> = { queuedAt = now, bytes = encoded, actor = actor, handle = handle, latest = latest }
		table.insert(state.queue, job)
		state.pendingCount += 1
		state.pool.pendingCount += 1
		Metrics.Adjust(state.diagnostics, "hintSendRecords", 1)

		if latest ~= nil then
			latest.job = job
		end
	end
end

local function release<T>(state: State<T>, job: Job<T>, dropped: boolean?): ()
	if dropped then
		Metrics.Count(state.diagnostics, "hintsDropped", 1)
		Metrics.Observe(state.diagnostics, "hintSendQueueResidenceSeconds", math.max(0, state.now() - job.queuedAt))
	end

	local bytes = buffer.len(job.bytes)

	state.pendingCount -= 1
	state.pendingBytes -= bytes
	state.pool.pendingCount -= 1
	state.pool.pendingBytes -= bytes
	Metrics.Adjust(state.diagnostics, "hintSendRecords", -1)
	Metrics.Adjust(state.diagnostics, "hintSendBytes", -bytes)
end

function Outbox.Select<T>(state: State<T>, maxVisits: number, maxBytes: number, eligible: (Job<T>) -> boolean): Batch<T>
	local batch: Batch<T> = { jobs = {}, records = {}, bytes = Constants.PACKET_HEADER_BYTES, work = 0 }

	while #state.queue > 0 and batch.work < maxVisits and #batch.records < Constants.MAX_RECORDS do
		local job = state.queue[1]

		batch.work += 1
		Metrics.Count(state.diagnostics, "hintSendVisits", 1)
		local valid = eligible(job)

		if
			valid
			and (
				batch.bytes + buffer.len(job.bytes) > Constants.MAX_PACKET_BYTES
				or batch.bytes + buffer.len(job.bytes) > maxBytes
			)
		then
			Metrics.Count(state.diagnostics, "hintUnproductiveInspections", 1)
			break
		end

		table.remove(state.queue, 1)
		Metrics.Observe(state.diagnostics, "hintSendQueueResidenceSeconds", math.max(0, state.now() - job.queuedAt))

		if job.latest ~= nil then
			job.latest.job = nil
		end

		if valid then
			table.insert(batch.jobs, job)
			table.insert(batch.records, job.bytes)
			batch.bytes += buffer.len(job.bytes)
		else
			Metrics.Count(state.diagnostics, "hintUnproductiveInspections", 1)
			release(state, job, true)
		end
	end

	return batch
end

-- A selected batch is the sole owner of its jobs until send unwind. Destroy and
-- retirement affect queued jobs only; neither can release these leases twice.
function Outbox.Settle<T>(state: State<T>, batch: Batch<T>): ()
	for _, job in batch.jobs do
		release(state, job)
	end

	table.clear(batch.jobs)
end

function Outbox.ForgetActor<T>(state: State<T>, actor: T): ()
	for index = #state.queue, 1, -1 do
		local job = state.queue[index]

		if job.actor == actor then
			table.remove(state.queue, index)
			release(state, job, true)
		end
	end

	for key, latest in state.latest do
		if latest.actor == actor then
			state.latest[key] = nil
			state.latestCount -= 1
			state.pool.latestCount -= 1
			Metrics.Adjust(state.diagnostics, "hintLatestKeys", -1)
		end
	end
end

function Outbox.Destroy<T>(state: State<T>): ()
	for _, job in state.queue do
		release(state, job, true)
	end

	state.pool.latestCount -= state.latestCount
	Metrics.Adjust(state.diagnostics, "hintLatestKeys", -state.latestCount)
	state.queue, state.latest, state.latestCount = {}, {}, 0
end

return Outbox
