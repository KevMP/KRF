--!strict
local Types = require(script.Parent.types)
local ReplicationTypes = require(script.Parent.Parent.Replication.types)
local SharedNetworkingTypes = require(script.Parent.Parent.Parent.shared.Networking.types)
local ActorTypes = require(script.Parent.Parent.Actor.types)
local WireCodec = require(script.Parent.Parent.Parent.shared.Networking.ActorStreamCodec)
local Streams = require(script.Parent.utils.ActorRecipientStream)
local Projections = require(script.Parent.utils.ActorRecipientProjection)
local RecipientSelection = require(script.Parent.utils.ActorRecipientSelection)
local Constants = require(script.Parent.Parent.Parent.shared.Networking.utils.ActorProtocolConstants)

type Stream = Streams.Stream

type Connection = {
	player: Player,
	nextHandle: number,
	actors: { [ActorTypes.Actor]: Stream },
	handles: { [number]: Stream },
	active: { Stream },
	queued: boolean,
	-- Reserved work is staged; Pending may still occupy a client assembly after local recapture/fault.
	-- A reliably queued End/Halt/Remove precedes new Begins; connection close also releases capacity.
	transfers: { [Stream]: "Reserved" | "Pending" },
}

type Delivery = { stream: Stream, record: SharedNetworkingTypes.ActorStreamRecord }

type Packet = {
	connection: Connection,
	bytes: number,
	records: { SharedNetworkingTypes.ActorStreamRecord },
	deliveries: { Delivery },
}

local ActorAwarenessRuntime = {}
ActorAwarenessRuntime.__index = ActorAwarenessRuntime

type RuntimeState = {
	codec: SharedNetworkingTypes.ActorStreamCodec,
	measuredRecords: { [Types.PublicationFilteredCommit]: number },
	dependencies: Types.ActorAwarenessDependencies,
	options: Types.ActorAwarenessOptions,
	connections: { [Player]: Connection },
	owners: { [ActorTypes.Actor]: Player },
	players: { [Player]: ActorTypes.Actor },
	models: { [Model]: ActorTypes.Actor },
	projections: Projections.Runtime,
	active: { Connection },
	disconnects: { () -> () },
	destroyed: boolean,
	stepping: boolean,
}

type Runtime = typeof(setmetatable({} :: RuntimeState, ActorAwarenessRuntime))

function ActorAwarenessRuntime._measureRecord(self: Runtime, commit: Types.PublicationFilteredCommit): number
	local cached: number? = self.measuredRecords[commit]

	if cached ~= nil then
		return cached
	end

	-- Publication projections and scheduler compositions are immutable once queued. Weak
	-- keys do not retain publication history after the recipient queues release it.
	-- Handle/revision are fixed-width U32s, so size is recipient-independent.
	local size: number = self.codec.Measure({
		{ kind = "Commit", handle = 1, revision = 1, patches = commit.patches, events = commit.events },
	}) or math.huge

	self.measuredRecords[commit] = size

	return size
end

function ActorAwarenessRuntime._activate(self: Runtime, stream: Stream): ()
	local connection: Connection? = self.connections[stream.player]

	if connection == nil or (stream.failed and not stream.removed and not stream.haltPending) or stream.active then
		return
	end

	stream.active = true
	table.insert(connection.active, stream)

	if not connection.queued then
		connection.queued = true
		table.insert(self.active, connection)
	end
end

function ActorAwarenessRuntime._aware(self: Runtime, connection: Connection, actor: ActorTypes.Actor): ()
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

	local stream: Stream = Streams.new(actor, connection.player, connection.nextHandle, self.options, {
		Project = function(
			projectedActor: ActorTypes.Actor,
			player: Player
		): (number?, Projections.Projection?, string?)
			return self.projections:Capture(projectedActor, self.owners[projectedActor] == player)
		end,
		Activate = function(active: Stream): ()
			self:_activate(active)
		end,
		ReportFault = self.dependencies.ReportFault,
		MeasureRecord = function(commit: Types.PublicationFilteredCommit): number
			return self:_measureRecord(commit)
		end,
	})

	connection.nextHandle += 1
	connection.actors[actor] = stream
	connection.handles[stream.handle] = stream
	stream:Capture()
end

function ActorAwarenessRuntime.OnActorRegistered(self: Runtime, actor: ActorTypes.Actor): ()
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

function ActorAwarenessRuntime.RefreshPlayerAssociation(self: Runtime, actor: ActorTypes.Actor): ()
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
			stream:Capture()
		end
	end
end

function ActorAwarenessRuntime.OnActorUnregistering(self: Runtime, actor: ActorTypes.Actor): ()
	if self.destroyed then
		return
	end

	local owner: Player? = self.owners[actor]

	if owner ~= nil and self.players[owner] == actor then
		self.players[owner] = nil
	end

	self.owners[actor] = nil
	self.projections:Forget(actor)

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
		stream:Retire()
	end
end

function ActorAwarenessRuntime.GetActorForPlayer(self: Runtime, player: Player): ActorTypes.Actor?
	return self.players[player]
end

function ActorAwarenessRuntime.GetPlayerForActor(self: Runtime, actor: ActorTypes.Actor): Player?
	return self.owners[actor]
end

function ActorAwarenessRuntime.GetHandle(self: Runtime, player: Player, actor: ActorTypes.Actor): number?
	local connection: Connection? = self.connections[player]
	local stream: Stream? = if connection ~= nil then connection.actors[actor] else nil

	return if stream ~= nil then stream.handle else nil
end

function ActorAwarenessRuntime.IsAware(self: Runtime, player: Player, actor: ActorTypes.Actor): boolean
	return self:GetHandle(player, actor) ~= nil
end

function ActorAwarenessRuntime.RequestReplacementBaseline(
	self: Runtime,
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

	local captured: boolean = stream:Capture()

	return captured, if captured then nil else "ActorStreamHalted"
end

function ActorAwarenessRuntime._step(self: Runtime, maxBytes: number, maxRecords: number): ()
	if self.destroyed or maxBytes <= 0 or maxRecords <= 0 then
		return
	end

	local visits: number = 0
	local deliveryBudget: number = maxBytes
	local limit: number = maxRecords * 2
	local packets: { Packet } = {}
	local currentPackets: { [Connection]: Packet } = {}
	local visited: { [Stream]: boolean } = {}

	while #self.active > 0 and maxRecords > 0 and maxBytes > 0 and visits < limit do
		visits += 1

		local connection: Connection = table.remove(self.active, 1) :: Connection
		connection.queued = false

		local stream: Stream = table.remove(connection.active, 1) :: Stream
		stream.active = false

		if self.connections[connection.player] == connection then
			-- Stage at most one record per Actor in this pass. Physical packets can batch Actors.
			local count: number = 0

			for _ in connection.transfers do
				count += 1
			end

			local canBegin: boolean = connection.transfers[stream] ~= nil or count < Constants.MAX_PENDING_BASELINES
			local record: SharedNetworkingTypes.ActorStreamRecord? = nil
			local measuredBytes: number? = nil

			if not visited[stream] then
				visited[stream] = true
				record, measuredBytes = stream:Prepare(maxBytes, canBegin, deliveryBudget)
			end

			if record ~= nil then
				local size: number? = measuredBytes
				local reason: string? = nil

				if size == nil then
					size, reason = self.codec.Measure({ record })
				end

				if size == nil then
					stream:Fault(reason or "InvalidActorPacket")
				elseif size <= maxBytes then
					local packet: Packet? = currentPackets[connection]

					if packet == nil or packet.bytes + size > Constants.MAX_PACKET_BYTES then
						local created: Packet = { connection = connection, bytes = 0, records = {}, deliveries = {} }
						packet = created
						currentPackets[connection] = created
						table.insert(packets, created)
					end

					assert(packet ~= nil, "Expected staged packet")

					if record.kind == "BaselineBegin" then
						if connection.transfers[stream] == nil then
							connection.transfers[stream] = "Reserved"
						end
					end

					packet.bytes += size
					table.insert(packet.records, record)
					table.insert(packet.deliveries, { stream = stream, record = record })
					maxBytes -= size
					maxRecords -= 1
				end
			end

			if stream:HasWork() then
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
				local record: SharedNetworkingTypes.ActorStreamRecord = delivery.record

				if record.kind == "BaselineBegin" then
					packet.connection.transfers[delivery.stream] = "Pending"
				elseif record.kind == "BaselineEnd" or record.kind == "ActorRemove" or record.kind == "ActorHalt" then
					packet.connection.transfers[delivery.stream] = nil
				end

				delivery.stream:Sent(record)
			else
				if packet.connection.transfers[delivery.stream] == "Reserved" then
					packet.connection.transfers[delivery.stream] = nil
				end

				delivery.stream:Fault(reason or "ActorSendFailed")
			end
		end
	end
end

function ActorAwarenessRuntime.Step(self: Runtime, maxBytes: number, maxRecords: number): ()
	if self.stepping then
		return
	end

	self.stepping = true
	local success: boolean, failure: any = pcall(self._step, self, maxBytes, maxRecords)
	self.stepping = false

	if not success then
		error(failure, 0)
	end
end

function ActorAwarenessRuntime._close(self: Runtime, player: Player): ()
	local connection: Connection? = self.connections[player]

	if connection == nil then
		return
	end

	self.connections[player] = nil

	for _, stream: Stream in connection.actors do
		stream:Destroy()
	end

	for _, stream: Stream in connection.active do
		stream:Destroy()
	end

	table.clear(connection.transfers)
	table.clear(connection.actors)
	table.clear(connection.handles)
	table.clear(connection.active)
	local index: number? = table.find(self.active, connection)

	if index ~= nil then
		table.remove(self.active, index)
	end
end

function ActorAwarenessRuntime.Destroy(self: Runtime): ()
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
	self.projections:Destroy()
	table.clear(self.measuredRecords)
	table.clear(self.active)
end

function ActorAwarenessRuntime.new(
	publication: Types.PublicationRuntime,
	catalog: ReplicationTypes.PreparedReplicationDomainCatalog,
	protocol: SharedNetworkingTypes.ClientProtocol,
	dependencies: Types.ActorAwarenessDependencies,
	options: Types.ActorAwarenessOptions
): Types.ActorAwarenessRuntime
	local schemas: SharedNetworkingTypes.ActorSchemaCatalog = {}

	for id: string, definition: ReplicationTypes.LoadedReplicationDomainDefinition in catalog.definitionsById do
		schemas[id] = definition.state
	end

	local codec: SharedNetworkingTypes.ActorStreamCodec = WireCodec.Compile(protocol, schemas)

	local state: RuntimeState = {
		codec = codec,
		measuredRecords = setmetatable({}, { __mode = "k" }),
		dependencies = dependencies,
		options = options,
		connections = {},
		owners = {},
		players = {},
		models = {},
		projections = Projections.new(publication, catalog, codec),
		active = {},
		disconnects = {},
		destroyed = false,
		stepping = false,
	}

	local self: Runtime = setmetatable(state, ActorAwarenessRuntime)

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

			local connection: Connection = {
				player = player,
				nextHandle = 1,
				actors = {},
				handles = {},
				active = {},
				queued = false,
				transfers = {},
			}

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
		publication:ObserveCommits(function(commit: Types.PublicationCommit)
			if self.destroyed then
				return
			end

			local public: Types.PublicationFilteredCommit = self.projections:PublicCommit(commit)

			local owner: Types.PublicationFilteredCommit =
				table.freeze({ sequence = commit.sequence, patches = commit.patches, events = commit.events })

			for _, connection: Connection in self.connections do
				local stream: Stream? = connection.actors[commit.actor]

				if stream == nil then
					continue
				end

				local projected: Types.PublicationFilteredCommit = if self.owners[commit.actor]
						== connection.player
					then owner
					else public

				stream:Enqueue(projected)
			end
		end)
	)

	-- The public interface erases private state; Luau treats metatable method receivers invariantly.
	return self :: Types.ActorAwarenessRuntime
end

return ActorAwarenessRuntime
