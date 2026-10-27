--!strict
local Types = require(script.Parent.Parent.types)
local SharedTypes = require(script.Parent.Parent.Parent.Parent.shared.Networking.types)
local Metrics = require(script.Parent.Parent.Parent.Parent.shared.Networking.utils.NetworkingMetrics)
local Timer = require(script.Parent.Parent.Parent.Parent.shared.Networking.utils.CommandTimer)
type Entry = { outcome: Types.CommandOutcome, bytes: number, expires: number }

local History = {}
History.__index = History

type State = {
	diagnostics: SharedTypes.DiagnosticCollector?,
	now: () -> number,
	schedule: (number, () -> ()) -> () -> (),
	entries: { [number]: Entry },
	order: { number },
	bytes: number,
	maxEntries: number,
	maxBytes: number,
	lifetime: number,
	cancel: (() -> ())?,
	active: boolean,
}

export type Runtime = typeof(setmetatable({} :: State, History))

function History.new(
	diagnostics: SharedTypes.DiagnosticCollector?,
	now: () -> number,
	schedule: ((number, () -> ()) -> () -> ())?,
	maxEntries: number,
	maxBytes: number,
	lifetime: number
): Runtime
	return setmetatable({
		diagnostics = diagnostics,
		now = now,
		schedule = schedule or Timer.Schedule,
		entries = {},
		order = {},
		bytes = 0,
		maxEntries = maxEntries,
		maxBytes = maxBytes,
		lifetime = lifetime,
		active = true,
	}, History)
end

function History._evict(self: Runtime): ()
	local id = assert(table.remove(self.order, 1))
	local entry = self.entries[id]

	self.entries[id] = nil
	self.bytes -= entry.bytes
	Metrics.Adjust(self.diagnostics, "commandHistoryEntries", -1)
	Metrics.Adjust(self.diagnostics, "commandHistoryBytes", -entry.bytes)
end

function History.Expire(self: Runtime): ()
	while #self.order > 0 and self.entries[self.order[1]].expires <= self.now() do
		self:_evict()
	end
end

function History.Get(self: Runtime, id: number): Types.CommandOutcome?
	self:Expire()
	local entry = self.entries[id]

	return if entry ~= nil then entry.outcome else nil
end

function History._arm(self: Runtime): ()
	if self.cancel ~= nil then
		self.cancel()
		self.cancel = nil
	end

	local id = self.order[1]

	if id == nil or not self.active then
		return
	end

	self.cancel = self.schedule(math.max(0, self.entries[id].expires - self.now()), function(): ()
		self.cancel = nil

		if self.active then
			self:Expire()
			self:_arm()
		end
	end)
end

-- Only schema-owned outcomes enter history, before the dispatch owner advances
-- the same connection's FIFO. The helper never owns jobs or result reservations.
function History.Retain(self: Runtime, outcome: Types.CommandOutcome, bytes: number): ()
	self:Expire()

	while #self.order > 0 and (#self.order >= self.maxEntries or self.bytes + bytes > self.maxBytes) do
		self:_evict()
	end

	if self.maxEntries > 0 and bytes <= self.maxBytes then
		self.entries[outcome.requestId] = { outcome = outcome, bytes = bytes, expires = self.now() + self.lifetime }
		table.insert(self.order, outcome.requestId)
		self.bytes += bytes
		Metrics.Adjust(self.diagnostics, "commandHistoryEntries", 1)
		Metrics.Adjust(self.diagnostics, "commandHistoryBytes", bytes)
	end

	self:_arm()
end

function History.Destroy(self: Runtime): ()
	if not self.active then
		return
	end

	self.active = false

	if self.cancel ~= nil then
		pcall(self.cancel)
		self.cancel = nil
	end

	Metrics.Set(self.diagnostics, "commandHistoryEntries", 0)
	Metrics.Set(self.diagnostics, "commandHistoryBytes", 0)
	table.clear(self.entries)
	table.clear(self.order)
	self.bytes = 0
end

return History
