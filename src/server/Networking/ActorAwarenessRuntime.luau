--!strict
local Types = require(script.Parent.AwarenessTypes)
local PublicationTypes = require(script.Parent.PublicationTypes)
local ReplicationTypes = require(script.Parent.Parent.Replication.types)
local ProtocolTypes = require(script.Parent.Parent.Parent.shared.Networking.ProtocolTypes)
local ActorTypes = require(script.Parent.Parent.Actor.types)
local WireTypes = require(script.Parent.Parent.Parent.shared.Networking.ActorStreamTypes)
local WireCodec = require(script.Parent.Parent.Parent.shared.Networking.ActorStreamCodec)
local Scheduler = require(script.Parent.PublicationScheduler)
local RecipientSelection = require(script.Parent.ActorRecipientSelection)
local Constants = require(script.Parent.Parent.Parent.shared.Networking.ActorProtocolConstants)

type Baseline = { body: buffer, offset: number, phase: number }
type Projection = { domains: { [string]: WireTypes.DomainTruth }, body: buffer?, reason: string? }
type BaselineCache = { sequence: number, public: Projection?, owner: Projection? }
type Stream = {
	actor: ActorTypes.Actor,
	player: Player,
	handle: number,
	generation: number,
	revision: number,
	fence: number,
	identitySent: boolean,
	baseline: Baseline?,
	recapture: boolean,
	removed: boolean,
	failed: boolean,
	active: boolean,
	scheduler: PublicationTypes.Scheduler,
	key: PublicationTypes.StreamKey,
}
type Connection = {
	player: Player,
	nextHandle: number,
	actors: { [ActorTypes.Actor]: Stream },
	handles: { [number]: Stream },
	active: { Stream },
	queued: boolean,
}
type Delivery = { stream: Stream, record: WireTypes.Record }
type Packet = { connection: Connection, bytes: number, records: { WireTypes.Record }, deliveries: { Delivery } }
local ActorAwarenessRuntime = {}
ActorAwarenessRuntime.__index = ActorAwarenessRuntime

function ActorAwarenessRuntime._activate(self: any, stream: Stream): ()
	local connection: Connection? = self.connections[stream.player]
	if connection == nil or (stream.failed and not stream.removed) or stream.active then
		return
	end
	stream.active = true
	table.insert(connection.active, stream)
	if not connection.queued then
		connection.queued = true
		table.insert(self.active, connection)
	end
end

function ActorAwarenessRuntime._fault(self: any, stream: Stream, reason: string): ()
	local reported: boolean = stream.failed
	stream.failed = true
	stream.baseline = nil
	stream.recapture = false
	stream.removed = false
	stream.scheduler:Destroy()
	if not reported then
		self.dependencies.ReportFault({ player = stream.player, actorId = stream.actor:GetId(), reason = reason })
	end
end

function ActorAwarenessRuntime._visible(self: any, player: Player, actor: ActorTypes.Actor, id: string): boolean
	local definition: ReplicationTypes.LoadedReplicationDomainDefinition? = self.catalog.definitionsById[id]
	return definition ~= nil and (definition.audience == "All" or self.owners[actor] == player)
end

function ActorAwarenessRuntime._capture(self: any, stream: Stream): boolean
	local captured: PublicationTypes.Baseline? = self.publication:CaptureBaseline(stream.actor)
	if captured == nil then
		self:_fault(stream, "ActorBaselineMissing")
		return false
	end
	local cache: BaselineCache? = self.baselines[stream.actor]
	if cache == nil or cache.sequence ~= captured.sequence then
		local created: BaselineCache = { sequence = captured.sequence, public = nil, owner = nil }
		cache = created
		self.baselines[stream.actor] = cache
	end
	assert(cache ~= nil, "Expected canonical baseline cache")
	local isOwner: boolean = self.owners[stream.actor] == stream.player
	local projected: Projection? = if isOwner then cache.owner else cache.public
	if projected == nil then
		local domains: { [string]: WireTypes.DomainTruth } = {}
		for id: string, truth: PublicationTypes.DomainTruth in captured.domains do
			if self:_visible(stream.player, stream.actor, id) then
				domains[id] = truth
			end
		end
		table.freeze(domains)
		local body: buffer?, reason: string? = self.codec.EncodeBaseline(domains)
		local created: Projection = { domains = domains, body = body, reason = reason }
		projected = created
		if isOwner then
			cache.owner = projected
		else
			cache.public = projected
		end
	end
	assert(projected ~= nil, "Expected recipient baseline projection")
	local body: buffer?, reason: string? = projected.body, projected.reason
	if body == nil then
		self:_fault(stream, reason or "InvalidActorBaseline")
		return false
	end
	if buffer.len(body) > self.options.maxBaselineBytes then
		self:_fault(stream, "ActorBaselineTooLarge")
		return false
	end
	if stream.generation >= (self.options.maxGeneration or Constants.MAX_COUNTER) then
		self:_fault(stream, "ActorGenerationExhausted")
		return false
	end
	stream.generation += 1
	stream.fence = captured.sequence
	stream.baseline = { body = body, offset = 0, phase = 0 }
	stream.recapture = false
	stream.scheduler:ResetAfterBaseline(stream.key, projected.domains)
	self:_activate(stream)
	return true
end

function ActorAwarenessRuntime._aware(self: any, connection: Connection, actor: ActorTypes.Actor): ()
	if connection.actors[actor] ~= nil or not actor.enabled then
		return
	end
	if not self.dependencies.IsClientReady(connection.player) then
		return
	end
	if not RecipientSelection.ShouldBeAware(connection.player, actor) then
		return
	end
	if connection.nextHandle > self.options.maxHandle then
		self.dependencies.ReportFault({
			player = connection.player,
			actorId = actor:GetId(),
			reason = "ActorHandleExhausted",
		})
		return
	end
	local scheduler: PublicationTypes.Scheduler = Scheduler.new({
		maxBarriers = self.options.maxEvents,
		maxEvents = self.options.maxEvents,
		maxQueuedBytes = self.options.maxQueuedBytes,
		MeasureRecord = function(commit: PublicationTypes.FilteredCommit): number
			local size: number? = self.codec.Measure({
				{ kind = "Commit", handle = 1, revision = 1, patches = commit.patches, events = commit.events },
			})
			return size or math.huge
		end,
	})
	local stream: Stream = {
		actor = actor,
		player = connection.player,
		handle = connection.nextHandle,
		generation = 0,
		revision = 0,
		fence = 0,
		identitySent = false,
		baseline = nil,
		recapture = false,
		removed = false,
		failed = false,
		active = false,
		scheduler = scheduler,
		key = { recipient = connection.player, actor = actor },
	}
	connection.nextHandle += 1
	connection.actors[actor] = stream
	connection.handles[stream.handle] = stream
	self:_capture(stream)
end

function ActorAwarenessRuntime.OnActorRegistered(self: any, actor: ActorTypes.Actor): ()
	if self.destroyed then
		return
	end
	if actor.model ~= nil then
		self.models[actor.model] = actor
	end
	self:RefreshPlayerAssociation(actor)
	for _, connection: Connection in self.connections do
		self:_aware(connection, actor)
	end
end

function ActorAwarenessRuntime.RefreshPlayerAssociation(self: any, actor: ActorTypes.Actor): ()
	if self.destroyed then
		return
	end
	local previous: Player? = self.owners[actor]
	local current: Player? = if actor.model ~= nil then self.dependencies.GetPlayerFromCharacter(actor.model) else nil
	if previous == current then
		return
	end
	if previous ~= nil and self.players[previous] == actor then
		self.players[previous] = nil
	end
	self.owners[actor] = current
	if current ~= nil then
		self.players[current] = actor
	end
	for _, player: Player? in { previous, current } do
		if player == nil then
			continue
		end
		local connection: Connection? = self.connections[player]
		local stream: Stream? = if connection ~= nil then connection.actors[actor] else nil
		if stream ~= nil and not stream.failed then
			self:_capture(stream)
		end
	end
end

function ActorAwarenessRuntime.OnActorUnregistering(self: any, actor: ActorTypes.Actor): ()
	if self.destroyed then
		return
	end
	local owner: Player? = self.owners[actor]
	if owner ~= nil and self.players[owner] == actor then
		self.players[owner] = nil
	end
	self.owners[actor] = nil
	self.baselines[actor] = nil
	if actor.model ~= nil and self.models[actor.model] == actor then
		self.models[actor.model] = nil
	end
	for _, connection: Connection in self.connections do
		local stream: Stream? = connection.actors[actor]
		if stream == nil then
			continue
		end
		connection.actors[actor] = nil
		connection.handles[stream.handle] = nil
		stream.scheduler:Destroy()
		stream.baseline = nil
		stream.recapture = false
		stream.removed = true
		self:_activate(stream)
	end
end

function ActorAwarenessRuntime.GetActorForPlayer(self: any, player: Player): ActorTypes.Actor?
	return self.players[player]
end
function ActorAwarenessRuntime.GetPlayerForActor(self: any, actor: ActorTypes.Actor): Player?
	return self.owners[actor]
end
function ActorAwarenessRuntime.GetHandle(self: any, player: Player, actor: ActorTypes.Actor): number?
	local connection: Connection? = self.connections[player]
	local stream: Stream? = if connection ~= nil then connection.actors[actor] else nil
	return if stream ~= nil then stream.handle else nil
end
function ActorAwarenessRuntime.IsAware(self: any, player: Player, actor: ActorTypes.Actor): boolean
	return self:GetHandle(player, actor) ~= nil
end

function ActorAwarenessRuntime.RequestReplacementBaseline(
	self: any,
	player: Player,
	handle: number,
	_reason: string?
): (boolean, string?)
	if handle <= 0 or handle > Constants.MAX_COUNTER or handle % 1 ~= 0 then
		return false, "InvalidActorHandle"
	end
	local connection: Connection? = self.connections[player]
	if connection == nil or not self.dependencies.IsClientReady(player) then
		return false, "ClientNotReady"
	end
	local stream: Stream? = connection.handles[handle]
	if stream == nil then
		return false, "UnknownActorHandle"
	end
	if stream.baseline ~= nil or stream.recapture then
		return false, "BaselineAlreadyPending"
	end
	if stream.failed then
		return false, "ActorStreamHalted"
	end
	local captured: boolean = self:_capture(stream)
	return captured, if captured then nil else "ActorStreamHalted"
end

function ActorAwarenessRuntime._next(self: any, stream: Stream, maxBytes: number): WireTypes.Record?
	if stream.removed then
		return { kind = "ActorRemove", handle = stream.handle }
	end
	if stream.failed then
		return nil
	end
	if stream.recapture and not self:_capture(stream) then
		return nil
	end
	local pending: Baseline? = stream.baseline
	if pending ~= nil then
		if pending.phase == 0 then
			return {
				kind = "BaselineBegin",
				handle = stream.handle,
				actorId = if stream.identitySent then nil else stream.actor:GetId(),
				generation = stream.generation,
				totalBytes = buffer.len(pending.body),
			}
		elseif pending.offset < buffer.len(pending.body) then
			-- Header and fixed Chunk framing consume 26 bytes in a single-record packet.
			local length: number =
				math.min(self.options.maxChunkBytes, buffer.len(pending.body) - pending.offset, maxBytes - 26)
			if length <= 0 then
				return nil
			end
			local chunk: buffer = buffer.create(length)
			buffer.copy(chunk, 0, pending.body, pending.offset, length)
			return {
				kind = "BaselineChunk",
				handle = stream.handle,
				generation = stream.generation,
				offset = pending.offset,
				bytes = chunk,
			}
		end
		if stream.revision >= self.options.maxRevision then
			self:_fault(stream, "ActorRevisionExhausted")
			return nil
		end
		return {
			kind = "BaselineEnd",
			handle = stream.handle,
			generation = stream.generation,
			revision = stream.revision + 1,
		}
	end
	if stream.scheduler:GetStreamStatus(stream.key).pendingRecords == 0 then
		return nil
	end
	if stream.revision >= self.options.maxRevision then
		self:_fault(stream, "ActorRevisionExhausted")
		return nil
	end
	local drained: PublicationTypes.DrainResult = stream.scheduler:DrainBudgeted(maxBytes, 1)
	local record: PublicationTypes.Record? = drained.records[1]
	if record == nil then
		return nil
	end
	return {
		kind = "Commit",
		handle = stream.handle,
		revision = stream.revision + 1,
		patches = record.commit.patches,
		events = record.commit.events,
	}
end

function ActorAwarenessRuntime._sent(_self: any, delivery: Delivery): ()
	local stream: Stream = delivery.stream
	local record: WireTypes.Record = delivery.record
	local pending: Baseline? = stream.baseline
	if record.kind == "BaselineBegin" then
		stream.identitySent = true
		if pending ~= nil and record.generation == stream.generation then
			pending.phase = 1
		end
	elseif record.kind == "BaselineChunk" then
		if pending ~= nil and record.generation == stream.generation then
			pending.offset += buffer.len(record.bytes)
		end
	elseif record.kind == "BaselineEnd" then
		if record.generation == stream.generation then
			stream.baseline = nil
		end
		stream.revision = record.revision
	elseif record.kind == "Commit" then
		stream.revision = record.revision
	else
		stream.removed = false
	end
end

function ActorAwarenessRuntime.Step(self: any, maxBytes: number, maxRecords: number): ()
	if self.destroyed or maxBytes <= 0 or maxRecords <= 0 then
		return
	end
	local visits: number = 0
	local limit: number = maxRecords * 2
	local packets: { Packet } = {}
	local currentPackets: { [Connection]: Packet } = {}
	local staged: { [Stream]: boolean } = {}
	while #self.active > 0 and maxRecords > 0 and maxBytes > 0 and visits < limit do
		visits += 1
		local connection: Connection = table.remove(self.active, 1) :: Connection
		connection.queued = false
		local stream: Stream = table.remove(connection.active, 1) :: Stream
		stream.active = false
		if self.connections[connection.player] == connection then
			-- Stage at most one record per Actor in this pass. Physical packets can batch Actors.
			local record: WireTypes.Record? = if staged[stream] then nil else self:_next(stream, maxBytes)
			if record ~= nil then
				local size: number?, reason: string? = self.codec.Measure({ record })
				if size == nil then
					self:_fault(stream, reason or "InvalidActorPacket")
				elseif size <= maxBytes then
					local packet: Packet? = currentPackets[connection]
					if packet == nil or packet.bytes + size > Constants.MAX_PACKET_BYTES then
						local created: Packet = { connection = connection, bytes = 0, records = {}, deliveries = {} }
						packet = created
						currentPackets[connection] = created
						table.insert(packets, created)
					end
					assert(packet ~= nil, "Expected staged packet")
					packet.bytes += size
					table.insert(packet.records, record)
					table.insert(packet.deliveries, { stream = stream, record = record })
					staged[stream] = true
					maxBytes -= size
					maxRecords -= 1
				end
			end
			if
				stream.baseline ~= nil
				or stream.recapture
				or stream.removed
				or stream.scheduler:GetStreamStatus(stream.key).pendingRecords > 0
			then
				self:_activate(stream)
			end
			if #connection.active > 0 and not connection.queued then
				connection.queued = true
				table.insert(self.active, connection)
			end
		end
	end
	for _, packet: Packet in packets do
		if self.connections[packet.connection.player] ~= packet.connection then
			continue
		end
		local payload: buffer?, reason: string? = self.codec.Encode(packet.records)
		local sent: boolean = false
		if payload ~= nil then
			sent, reason = self.dependencies.SendReliable(packet.connection.player, payload)
		end
		for _, delivery: Delivery in packet.deliveries do
			if sent then
				self:_sent(delivery)
			else
				self:_fault(delivery.stream, reason or "ActorSendFailed")
			end
		end
	end
end

function ActorAwarenessRuntime._close(self: any, player: Player): ()
	local connection: Connection? = self.connections[player]
	if connection == nil then
		return
	end
	self.connections[player] = nil
	for _, stream: Stream in connection.actors do
		stream.scheduler:Destroy()
	end
	for _, stream: Stream in connection.active do
		stream.scheduler:Destroy()
	end
	table.clear(connection.actors)
	table.clear(connection.handles)
	table.clear(connection.active)
	local index: number? = table.find(self.active, connection)
	if index ~= nil then
		table.remove(self.active, index)
	end
end

function ActorAwarenessRuntime.Destroy(self: any): ()
	if self.destroyed then
		return
	end
	self.destroyed = true
	for _, disconnect: () -> () in self.disconnects do
		disconnect()
	end
	for player: Player in self.connections do
		self:_close(player)
	end
	table.clear(self.disconnects)
	table.clear(self.owners)
	table.clear(self.players)
	table.clear(self.models)
	table.clear(self.baselines)
	table.clear(self.active)
end

function ActorAwarenessRuntime.new(
	publication: PublicationTypes.Runtime,
	catalog: ReplicationTypes.PreparedReplicationDomainCatalog,
	protocol: ProtocolTypes.ClientProtocol,
	dependencies: Types.Dependencies,
	options: Types.Options
): Types.Runtime
	local schemas: WireTypes.SchemaCatalog = {}
	for id: string, definition: ReplicationTypes.LoadedReplicationDomainDefinition in catalog.definitionsById do
		schemas[id] = definition.state
	end
	local self: any = setmetatable({
		publication = publication,
		catalog = catalog,
		codec = WireCodec.Compile(protocol, schemas),
		dependencies = dependencies,
		options = options,
		connections = {},
		owners = {},
		players = {},
		models = {},
		baselines = {},
		active = {},
		disconnects = {},
		destroyed = false,
	}, ActorAwarenessRuntime)
	for _, actor: ActorTypes.Actor in publication:GetAttachedActors() do
		self:OnActorRegistered(actor)
	end
	table.insert(
		self.disconnects,
		dependencies.ObserveAssociationChanged(function(model: Model)
			local actor: ActorTypes.Actor? = self.models[model]
			if actor ~= nil then
				self:RefreshPlayerAssociation(actor)
			end
		end)
	)
	table.insert(
		self.disconnects,
		dependencies.ObserveClientReady(function(player: Player)
			if self.destroyed or self.connections[player] ~= nil or not dependencies.IsClientReady(player) then
				return
			end
			local connection: Connection =
				{ player = player, nextHandle = 1, actors = {}, handles = {}, active = {}, queued = false }
			self.connections[player] = connection
			for _, actor: ActorTypes.Actor in publication:GetAttachedActors() do
				self:_aware(connection, actor)
			end
		end)
	)
	table.insert(
		self.disconnects,
		dependencies.ObserveClientClosed(function(player: Player)
			self:_close(player)
		end)
	)
	table.insert(
		self.disconnects,
		publication:ObserveCommits(function(commit: PublicationTypes.Commit)
			if self.destroyed then
				return
			end
			local cached: BaselineCache? = self.baselines[commit.actor]
			if cached ~= nil and cached.sequence < commit.sequence then
				-- Pending transfers retain their own immutable body; only reusable projections expire.
				self.baselines[commit.actor] = nil
			end
			local publicPatches: { PublicationTypes.DomainPatch } = {}
			local publicEvents: { PublicationTypes.Event } = {}
			for _, patch: PublicationTypes.DomainPatch in commit.patches do
				if self.catalog.definitionsById[patch.domainId].audience == "All" then
					table.insert(publicPatches, patch)
				end
			end
			for _, event: PublicationTypes.Event in commit.events do
				if self.catalog.definitionsById[event.domainId].audience == "All" then
					table.insert(publicEvents, event)
				end
			end
			table.freeze(publicPatches)
			table.freeze(publicEvents)
			local public: PublicationTypes.FilteredCommit =
				table.freeze({ sequence = commit.sequence, patches = publicPatches, events = publicEvents })
			local owner: PublicationTypes.FilteredCommit =
				table.freeze({ sequence = commit.sequence, patches = commit.patches, events = commit.events })
			for _, connection: Connection in self.connections do
				local stream: Stream? = connection.actors[commit.actor]
				if stream == nil or stream.failed or stream.recapture or commit.sequence <= stream.fence then
					continue
				end
				local projected: PublicationTypes.FilteredCommit = if self.owners[commit.actor]
						== connection.player
					then owner
					else public
				if #projected.patches == 0 and #projected.events == 0 then
					continue
				end
				local accepted: boolean = stream.scheduler:Enqueue(stream.key, projected)
				if not accepted then
					stream.recapture = true
					stream.baseline = nil
				end
				self:_activate(stream)
			end
		end)
	)
	return self :: Types.Runtime
end

return ActorAwarenessRuntime
