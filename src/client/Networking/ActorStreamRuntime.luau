--!strict
local Types = require(script.Parent.ActorStreamTypes)
local WireTypes = require(script.Parent.Parent.Parent.shared.Networking.ActorStreamTypes)

type Assembly = { generation: number, bytes: buffer, received: number, occupied: buffer }
type State = {
	record: { actorId: string, handle: number, model: Model? },
	generation: number,
	pending: Assembly?,
	halted: boolean,
}
local ActorStreamRuntime = {}
ActorStreamRuntime.__index = ActorStreamRuntime

type RuntimeState = {
	codec: WireTypes.Codec,
	consumer: Types.Consumer?,
	options: Types.Options,
	handles: { [number]: State },
	ids: { [string]: State },
	models: { [Model]: State },
	candidates: { [Instance]: Types.Candidate },
	candidatesByActorId: { [string]: { [Instance]: Types.Candidate } },
	retired: { [number]: boolean },
	pendingCount: number,
	destroyed: boolean,
	missingReported: boolean,
	disconnects: { () -> () },
}
type Runtime = typeof(setmetatable({} :: RuntimeState, ActorStreamRuntime))

function ActorStreamRuntime._unbind(self: Runtime, state: State): ()
	local model: Model? = state.record.model
	if model == nil then
		return
	end
	self.models[model] = nil
	state.record.model = nil
	if self.consumer ~= nil then
		self.consumer.OnModelUnbound(state.record, model)
	end
end

function ActorStreamRuntime._bind(self: Runtime, state: State): ()
	local candidates: { [Instance]: Types.Candidate }? = self.candidatesByActorId[state.record.actorId]
	if candidates == nil then
		return
	end
	for _, candidate: Types.Candidate in candidates do
		if state.record.model ~= nil then
			if state.record.model ~= candidate.model then
				self.options.ReportFault("ActorModelConflict")
			end
			continue
		end
		if self.models[candidate.model] ~= nil then
			self.options.ReportFault("ActorModelConflict")
			continue
		end
		state.record.model = candidate.model
		self.models[candidate.model] = state
		if self.consumer ~= nil then
			self.consumer.OnModelBound(state.record, candidate.model)
		end
	end
end

function ActorStreamRuntime._record(self: Runtime, record: WireTypes.Record): string?
	local consumer: Types.Consumer? = self.consumer
	assert(consumer ~= nil, "Expected installed Actor consumer")
	if self.retired[record.handle] then
		return "RetiredActorHandle"
	end
	local state: State? = self.handles[record.handle]
	if state ~= nil and state.halted and record.kind ~= "ActorRemove" and record.kind ~= "ActorHalt" then
		return "ActorStreamHalted"
	end
	if record.kind == "BaselineBegin" then
		if record.totalBytes > self.options.maxBaselineBytes then
			return "ActorBaselineTooLarge"
		end
		if state ~= nil then
			if record.actorId ~= nil and record.actorId ~= state.record.actorId then
				return "ActorHandleConflict"
			end
			if record.generation <= state.generation then
				return "StaleBaselineGeneration"
			end
		elseif record.actorId == nil then
			return "UnknownActorHandle"
		elseif self.ids[record.actorId] ~= nil then
			return "ActorIdConflict"
		end
		if (state == nil or state.pending == nil) and self.pendingCount >= self.options.maxPendingBaselines then
			return "PendingBaselineLimit"
		end
		if state == nil then
			assert(record.actorId ~= nil, "Expected initial Actor identity")
			local created: State = {
				record = { actorId = record.actorId, handle = record.handle, model = nil },
				generation = 0,
				pending = nil,
				halted = false,
			}
			state = created
			self.handles[record.handle] = state
			self.ids[record.actorId] = state
			self:_bind(state)
		end
		assert(state ~= nil, "Expected admitted Actor record")
		if state.pending == nil then
			self.pendingCount += 1
		end
		state.generation = record.generation
		state.pending = {
			generation = record.generation,
			bytes = buffer.create(record.totalBytes),
			received = 0,
			occupied = buffer.create(record.totalBytes),
		}
		return nil
	end
	if state == nil and record.kind == "ActorRemove" then
		self.retired[record.handle] = true
		return nil
	end
	if state == nil then
		return "UnknownActorHandle"
	end
	if record.kind == "ActorRemove" then
		self:_unbind(state)
		if state.pending ~= nil then
			self.pendingCount -= 1
		end
		self.retired[record.handle] = true
		self.handles[record.handle] = nil
		self.ids[state.record.actorId] = nil
		consumer.OnActorRemoved(state.record)
		return nil
	elseif record.kind == "ActorHalt" then
		if state.halted then
			return nil
		end
		if state.pending ~= nil then
			state.pending = nil
			self.pendingCount -= 1
		end
		state.halted = true
		consumer.OnActorHalted(state.record)
		return nil
	elseif record.kind == "Commit" then
		if state.pending ~= nil then
			return "BaselineNotComplete"
		end
		consumer.OnCommitReady(state.record, record.revision, record.patches, record.events)
		return nil
	end
	local pending: Assembly? = state.pending
	if pending == nil then
		return "BaselineNotPending"
	end
	if record.generation ~= pending.generation then
		return "StaleBaselineGeneration"
	end
	if record.kind == "BaselineChunk" then
		local length: number = buffer.len(record.bytes)
		local last: number = record.offset + length
		if length == 0 or last > buffer.len(pending.bytes) then
			return "BaselineChunkOutOfBounds"
		end
		for offset: number = record.offset, last - 1 do
			if buffer.readu8(pending.occupied, offset) ~= 0 then
				return "BaselineChunkOverlap"
			end
		end
		buffer.copy(pending.bytes, record.offset, record.bytes)
		buffer.fill(pending.occupied, record.offset, 1, length)
		pending.received += length
		return nil
	end
	if pending.received ~= buffer.len(pending.bytes) then
		return "BaselineIncomplete"
	end
	local domains: { [string]: WireTypes.DomainTruth }?, reason: string? = self.codec.DecodeBaseline(pending.bytes)
	if domains == nil then
		return reason
	end
	state.pending = nil
	self.pendingCount -= 1
	consumer.OnBaselineReady(state.record, record.revision, domains)
	return nil
end

function ActorStreamRuntime.Handle(self: Runtime, payload: any): (boolean, string?)
	if self.destroyed then
		return false, "ActorStreamDestroyed"
	end
	if self.consumer == nil then
		if not self.missingReported then
			self.missingReported = true
			self.options.ReportFault("ActorStreamConsumerMissing")
		end
		return false, "ActorStreamConsumerMissing"
	end
	local records: { WireTypes.Record }?, reason: string? = self.codec.Decode(payload)
	if records == nil then
		return false, reason
	end
	for _, record: WireTypes.Record in records do
		local failure: string? = self:_record(record)
		if failure ~= nil then
			self.options.ReportFault(failure)
			return false, failure
		end
	end
	return true, nil
end

function ActorStreamRuntime.GetByHandle(self: Runtime, handle: number): Types.ActorRecord?
	local state: State? = self.handles[handle]
	return if state ~= nil then state.record else nil
end

function ActorStreamRuntime.GetByActorId(self: Runtime, actorId: string): Types.ActorRecord?
	local state: State? = self.ids[actorId]
	return if state ~= nil then state.record else nil
end

function ActorStreamRuntime.GetByModel(self: Runtime, model: Model): Types.ActorRecord?
	local state: State? = self.models[model]
	return if state ~= nil then state.record else nil
end

function ActorStreamRuntime.Destroy(self: Runtime): ()
	if self.destroyed then
		return
	end
	self.destroyed = true
	for _, disconnect: () -> () in self.disconnects do
		disconnect()
	end
	for _, state: State in self.handles do
		self:_unbind(state)
	end
	table.clear(self.handles)
	table.clear(self.ids)
	table.clear(self.models)
	table.clear(self.candidates)
	table.clear(self.candidatesByActorId)
	table.clear(self.retired)
	table.clear(self.disconnects)
	self.pendingCount = 0
end

function ActorStreamRuntime.new(
	codec: WireTypes.Codec,
	consumer: Types.Consumer?,
	discovery: Types.Discovery,
	options: Types.Options
): Types.Runtime
	local runtimeState: RuntimeState = {
		codec = codec,
		consumer = consumer,
		options = options,
		handles = {},
		ids = {},
		models = {},
		candidates = {},
		candidatesByActorId = {},
		retired = {},
		pendingCount = 0,
		destroyed = false,
		missingReported = false,
		disconnects = {},
	}
	local self: Runtime = setmetatable(runtimeState, ActorStreamRuntime)
	local function added(candidate: Types.Candidate): ()
		if self.destroyed or self.candidates[candidate.marker] ~= nil then
			return
		end
		self.candidates[candidate.marker] = candidate
		local candidates: { [Instance]: Types.Candidate } = self.candidatesByActorId[candidate.actorId] or {}
		self.candidatesByActorId[candidate.actorId] = candidates
		candidates[candidate.marker] = candidate
		local state: State? = self.ids[candidate.actorId]
		if state ~= nil then
			self:_bind(state)
		end
	end
	table.insert(self.disconnects, discovery.ObserveAdded(added))
	table.insert(
		self.disconnects,
		discovery.ObserveRemoved(function(marker: Instance)
			if self.destroyed then
				return
			end
			local candidate: Types.Candidate? = self.candidates[marker]
			if candidate == nil then
				return
			end
			self.candidates[marker] = nil
			local candidates: { [Instance]: Types.Candidate }? = self.candidatesByActorId[candidate.actorId]
			if candidates ~= nil then
				candidates[marker] = nil
				if next(candidates) == nil then
					self.candidatesByActorId[candidate.actorId] = nil
				end
			end
			local state: State? = self.ids[candidate.actorId]
			if state ~= nil and state.record.model == candidate.model then
				-- Marker lifetime is separate from Model lifetime. Another marker for
				-- this Actor may still support the current binding.
				if candidates ~= nil then
					for _, remaining: Types.Candidate in candidates do
						if remaining.model == candidate.model then
							return
						end
					end
				end
				self:_unbind(state)
				self:_bind(state)
			end
		end)
	)
	for _, candidate: Types.Candidate in discovery.GetCandidates() do
		added(candidate)
	end
	-- The public interface erases private state; Luau treats metatable method receivers invariantly.
	return self :: Types.Runtime
end

return ActorStreamRuntime
