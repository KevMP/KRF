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
local CommandConstants = require(script.Parent.Parent.Parent.shared.Networking.utils.CommandConstants)
local CommandEgress = require(script.Parent.utils.CommandEgress)
local ActiveQueue = require(script.Parent.utils.ActiveQueue)
local StreamOrder = require(script.Parent.utils.ActorStreamOrder)
local WorkBudget = require(script.Parent.utils.ReliableWorkBudget)
local Backlog = require(script.Parent.utils.ReliableBacklog)

type Stream = Streams.Stream

type Connection = {
	egress: CommandEgress.State,
	player: Player,
	nextHandle: number,
	actors: { [ActorTypes.Actor]: Stream },
	handles: { [number]: Stream },
	active: ActiveQueue.Queue<Stream>,
	captures: ActiveQueue.Queue<Stream>,
	captureNode: ActiveQueue.Node<Connection>?,
	node: ActiveQueue.Node<Connection>?,
	orders: { Stream },
	waitEpoch: number,
	transferCount: number,
	-- Reserved work is staged; Pending may still occupy a client assembly after local recapture/fault.
	-- A reliably queued End/Halt/Remove precedes new Begins; connection close also releases capacity.
	transfers: { [Stream]: "Reserved" | "Pending" },
}

type Delivery = { stream: Stream, record: SharedNetworkingTypes.ActorStreamRecord, generation: number }

type Packet = {
	connection: Connection,
	bytes: number,
	records: { SharedNetworkingTypes.ActorStreamRecord },
	deliveries: { Delivery },
}

local ActorAwarenessRuntime = {}
ActorAwarenessRuntime.__index = ActorAwarenessRuntime

type RuntimeState = {
	publication: Types.PublicationRuntime,
	codec: SharedNetworkingTypes.ActorStreamCodec,
	measuredRecords: { [Types.PublicationFilteredCommit]: number },
	dependencies: Types.ActorAwarenessDependencies,
	options: Types.ActorAwarenessOptions,
	connections: { [Player]: Connection },
	owners: { [ActorTypes.Actor]: Player },
	players: { [Player]: ActorTypes.Actor },
	models: { [Model]: ActorTypes.Actor },
	projections: Projections.Runtime,
	active: ActiveQueue.Queue<Connection>,
	captures: ActiveQueue.Queue<Connection>,
	deferred: { Stream },
	waiting: { Connection },
	epoch: number,
	work: WorkBudget.Budget?,
	backlog: Types.ReliableBacklog,
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

function ActorAwarenessRuntime._activate(self: Runtime, connection: Connection, stream: Stream): ()
	if self.connections[stream.player] ~= connection then
		return
	end

	StreamOrder.Update(connection.orders, stream)
	self:_indexCapture(connection, stream)

	if stream.active or not stream:HasWork() then
		return
	end

	stream.active = true

	local node: ActiveQueue.Node<Stream>? = stream.queueNode

	if node == nil then
		local created: ActiveQueue.Node<Stream> = ActiveQueue.node(stream :: Stream)

		stream.queueNode = created
		node = created
	end

	assert(node ~= nil, "Expected active stream node")
	ActiveQueue.Push(connection.active, node)
	self:_queueConnection(connection)
end

-- Reference-only opportunity membership. Payloads remain in each stream's N3
-- queue; capture itself still runs through Prepare under the same causal gate.
function ActorAwarenessRuntime._indexCapture(self: Runtime, connection: Connection, stream: Stream): ()
	if stream.recapture then
		local node: ActiveQueue.Node<Stream>? = stream.captureNode

		if node == nil then
			local created: ActiveQueue.Node<Stream> = ActiveQueue.node(stream :: Stream)
			stream.captureNode, node = created, created
		end

		assert(node ~= nil, "Expected capture stream node")
		ActiveQueue.Push(connection.captures, node)
		local owner: ActiveQueue.Node<Connection>? = connection.captureNode

		if owner == nil then
			local created: ActiveQueue.Node<Connection> = ActiveQueue.node(connection :: Connection)
			connection.captureNode, owner = created, created
		end

		assert(owner ~= nil, "Expected capture connection node")
		ActiveQueue.Push(self.captures, owner)
	else
		if stream.captureNode ~= nil then
			ActiveQueue.Remove(stream.captureNode)
		end

		if connection.captures.count == 0 and connection.captureNode ~= nil then
			ActiveQueue.Remove(connection.captureNode)
		end
	end
end

function ActorAwarenessRuntime._claimCapture(
	self: Runtime,
	connection: Connection,
	stream: Stream,
	work: WorkBudget.Budget
): boolean
	if
		self.connections[stream.player] ~= connection
		or self.captures.first == nil
		or self.captures.first.value ~= connection
		or connection.captures.first == nil
		or connection.captures.first.value ~= stream
		or not WorkBudget.Take(work, "captures")
	then
		return false
	end

	ActiveQueue.Pop(connection.captures)
	ActiveQueue.Pop(self.captures)

	if connection.captures.count > 0 then
		ActiveQueue.Push(self.captures, connection.captureNode :: ActiveQueue.Node<Connection>)
	end

	return true
end

function ActorAwarenessRuntime._yieldCapture(self: Runtime, connection: Connection, stream: Stream): ()
	if self.connections[stream.player] ~= connection or not stream.recapture then
		return
	end

	if connection.captures.first ~= nil and connection.captures.first.value == stream then
		ActiveQueue.Pop(connection.captures)
		ActiveQueue.Push(connection.captures, stream.captureNode :: ActiveQueue.Node<Stream>)
	end

	if self.captures.first ~= nil and self.captures.first.value == connection then
		ActiveQueue.Pop(self.captures)
		ActiveQueue.Push(self.captures, connection.captureNode :: ActiveQueue.Node<Connection>)
	end
end

function ActorAwarenessRuntime._prioritizeCapture(self: Runtime, work: WorkBudget.Budget, maxRecords: number): ()
	if
		maxRecords < 2
		or self.captures.first == nil
		or not WorkBudget.Available(work, "captures")
		or not WorkBudget.Take(work, "priorities")
	then
		return
	end

	local connection = self.captures.first.value
	local first = connection.captures.first
	assert(first ~= nil, "Expected indexed capture opportunity")
	local stream = first.value
	local boundary = connection.egress.queue[1]

	if boundary ~= nil and not stream:HasWorkThrough(boundary.order) then
		self:_yieldCapture(connection, stream)

		return
	end

	local node, owner = stream.queueNode, connection.node

	if node ~= nil and owner ~= nil and node.queue == connection.active and owner.queue == self.active then
		-- One promoted capture opportunity cannot consume the whole record budget;
		-- all actual preparation/serialization still uses the normal bounded drain.
		ActiveQueue.Prioritize(connection.active, node)
		ActiveQueue.Prioritize(self.active, owner)
	end
end

function ActorAwarenessRuntime._queueConnection(self: Runtime, connection: Connection): ()
	if self.connections[connection.player] ~= connection then
		return
	end

	local node: ActiveQueue.Node<Connection>? = connection.node

	if node == nil then
		local created: ActiveQueue.Node<Connection> = ActiveQueue.node(connection :: Connection)

		connection.node = created
		node = created
	end

	assert(node ~= nil, "Expected active connection node")
	ActiveQueue.Push(self.active, node)
end

function ActorAwarenessRuntime.ReserveCommandResult(
	self: Runtime,
	player: Player,
	maxBytes: number
): (Types.CommandReservation?, string?)
	local connection: Connection? = self.connections[player]

	if self.destroyed or connection == nil or not self.dependencies.IsClientReady(player) then
		return nil, "ClientNotReady"
	end

	local reservation: Types.CommandReservation?, reason: string? = CommandEgress.Reserve(connection.egress, maxBytes)

	if reservation ~= nil then
		self:_queueConnection(connection)
	end

	return reservation, reason
end

function ActorAwarenessRuntime.ResolveActor(self: Runtime, player: Player, handle: number): (ActorTypes.Actor?, string?)
	if type(handle) ~= "number" or handle <= 0 or handle > CommandConstants.MAX_COUNTER or handle % 1 ~= 0 then
		return nil, "InvalidActorHandle"
	end

	local connection: Connection? = self.connections[player]

	if self.destroyed or connection == nil or not self.dependencies.IsClientReady(player) then
		return nil, "ClientNotReady"
	end

	local stream: Stream? = connection.handles[handle]

	if stream == nil then
		return nil, "UnknownActorHandle"
	end

	local actor: ActorTypes.Actor = stream.actor

	if
		stream.failed
		or stream.removed
		or connection.actors[actor] ~= stream
		or not actor.enabled
		or actor.model == nil
		or self.models[actor.model] ~= actor
		or not self.publication:IsActorAttached(actor)
	then
		return nil, "ActorUnavailable"
	end

	return actor, nil
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

	if connection.nextHandle > math.min(self.options.maxHandle, Constants.MAX_COUNTER) then
		self.dependencies.ReportFault({
			player = connection.player,
			actorId = actor:GetId(),
			reason = "ActorHandleExhausted",
		})

		return
	end

	local stream: Stream = Streams.new(actor, connection.player, connection.nextHandle, self.options, {
		Backlog = self.backlog,
		Current = function(): boolean
			return self.connections[connection.player] == connection
		end,
		DiscardProjection = function(projectedActor: ActorTypes.Actor, projection: Projections.Projection): ()
			self.projections:Discard(projectedActor, projection)
		end,
		GetOrder = function(): number
			return connection.egress.order
		end,
		ClaimCapture = function(active: Stream, work: WorkBudget.Budget): boolean
			return self:_claimCapture(connection, active, work)
		end,
		YieldCapture = function(active: Stream): ()
			self:_yieldCapture(connection, active)
		end,
		Project = function(
			projectedActor: ActorTypes.Actor,
			player: Player
		): (number?, Projections.Projection?, string?)
			return self.projections:Capture(projectedActor, self.owners[projectedActor] == player)
		end,
		Activate = function(active: Stream): ()
			self:_activate(connection, active)
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

	return captured,
		if captured
			then nil
			else if stream.recapture and not stream.failed then "ActorBaselineCapacity" else "ActorStreamHalted"
end

function ActorAwarenessRuntime._step(self: Runtime, maxBytes: number, maxRecords: number): ()
	if self.destroyed or maxBytes <= 0 or maxRecords <= 0 then
		return
	end

	local work = self.work :: WorkBudget.Budget
	self:_prioritizeCapture(work, maxRecords)
	local deliveryBudget = maxBytes
	local packets: { Packet } = {}
	local currentPackets: { [Connection]: Packet } = {}
	local reservedPackets = 0

	while self.active.count > 0 and maxRecords > 0 and maxBytes > 0 and WorkBudget.Take(work, "connections") do
		local connection = ActiveQueue.Pop(self.active) :: Connection

		if connection.waitEpoch ~= self.epoch then
			connection.waitEpoch = self.epoch
			table.insert(self.waiting, connection)
		end

		local front = connection.egress.queue[1]
		local sentResult = false

		if front ~= nil and front.payload ~= nil and currentPackets[connection] == nil then
			if not WorkBudget.Take(work, "checks") then
				break
			end

			if
				not StreamOrder.HasWorkThrough(connection.orders, front.order)
				and buffer.len(front.payload) <= maxBytes
				and work.used.sends + reservedPackets < work.limits.sends
			then
				local payload = front.payload
				WorkBudget.Take(work, "sends")
				local completed, sent = pcall(self.dependencies.SendReliable, connection.player, payload)
				maxBytes -= buffer.len(payload)
				maxRecords -= 1
				sentResult = true

				if completed and sent then
					CommandEgress.Release(connection.egress, front)
				elseif self.connections[connection.player] == connection then
					self:_close(connection.player)

					if self.dependencies.CloseConnection ~= nil then
						self.dependencies.CloseConnection(connection.player, "CommandResultSendFailed")
					end
				end
			end
		end

		if self.connections[connection.player] ~= connection then
			continue
		end

		if maxRecords <= 0 or maxBytes <= 0 then
			break
		end

		if connection.active.count == 0 then
			if sentResult and #connection.egress.queue > 0 then
				self:_queueConnection(connection)
			end

			continue
		end

		if
			not WorkBudget.Take(work, "streams")
			or not WorkBudget.Available(work, "prepares")
			or not WorkBudget.Available(work, "measurements")
		then
			break
		end

		local stream = ActiveQueue.Pop(connection.active) :: Stream
		stream:StageBaseline()
		-- Keep active membership while staged/blocked; reentrant publication cannot
		-- insert it again. Resume once, after all packet acknowledgements unwind.
		table.insert(self.deferred, stream)
		local packet = currentPackets[connection]
		local nextBytes = stream.scheduler:GetNextRecordBytes(stream.key)

		if packet ~= nil and nextBytes ~= nil and nextBytes > Constants.MAX_PACKET_BYTES - packet.bytes then
			packet = nil
		end

		local canStage = packet ~= nil
			or (work.used.sends + reservedPackets < work.limits.sends and reservedPackets < work.limits.encodes)

		if canStage then
			local boundary = connection.egress.queue[1]

			local available =
				math.min(maxBytes, Constants.MAX_PACKET_BYTES - (if packet ~= nil then packet.bytes else 0))

			stream.stagedOrder = stream:GetNextOrder()

			local staged = false

			local record, measuredBytes = stream:Prepare(
				available,
				connection.transfers[stream] ~= nil or connection.transferCount < Constants.MAX_PENDING_BASELINES,
				deliveryBudget,
				if boundary ~= nil then boundary.order else nil,
				work
			)

			if self.connections[connection.player] ~= connection then
				stream.stagedOrder = nil
				continue
			end

			if record ~= nil then
				local size, reason = measuredBytes, nil :: string?

				if size == nil and WorkBudget.Take(work, "measurements") then
					size, reason = self.codec.Measure({ record })
				end

				if size == nil then
					stream:Fault(reason or "InvalidActorPacket")
				elseif size <= available then
					if packet == nil then
						packet = { connection = connection, bytes = 0, records = {}, deliveries = {} }
						currentPackets[connection] = packet
						table.insert(packets, packet)
						reservedPackets += 1
					end

					assert(packet ~= nil, "Expected staged Actor packet")

					if record.kind == "BaselineBegin" and connection.transfers[stream] == nil then
						connection.transfers[stream] = "Reserved"
						connection.transferCount += 1
					end

					packet.bytes += size
					table.insert(packet.records, record)

					table.insert(
						packet.deliveries,
						{ stream = stream, record = record, generation = stream.generation }
					)

					staged = true
					maxBytes -= size
					maxRecords -= 1
				end
			end

			if not staged then
				stream.stagedOrder = nil

				if self.connections[connection.player] == connection then
					StreamOrder.Update(connection.orders, stream)
				end
			end
		end

		if connection.active.count > 0 then
			self:_queueConnection(connection)
		end
	end

	for _, packet in packets do
		local connection = packet.connection

		if self.connections[connection.player] ~= connection then
			continue
		end

		-- Earlier sends can retire, fault or replace another staged stream. Only
		-- current records enter the immutable Actor envelope; superseded history
		-- keeps its earliest position in recaptureOrder before the stage clears.
		local records, deliveries = packet.records, packet.deliveries
		local retained = 0
		local preparedCount = #deliveries

		for index = 1, preparedCount do
			local delivery = deliveries[index]
			local stream, record = delivery.stream, delivery.record

			local valid = if record.kind == "ActorRemove"
				then stream.removed
				else if record.kind == "ActorHalt"
					then stream.haltPending and not stream.removed
					else not stream.removed
						and not stream.failed
						and not stream.recapture
						and delivery.generation == stream.generation

			if valid then
				retained += 1
				records[retained] = record
				deliveries[retained] = delivery
			else
				stream.stagedOrder = nil

				if connection.transfers[stream] == "Reserved" then
					connection.transfers[stream] = nil
					connection.transferCount -= 1
				end

				StreamOrder.Update(connection.orders, stream)
			end
		end

		for index = preparedCount, retained + 1, -1 do
			records[index], deliveries[index] = nil, nil
		end

		if #records == 0 then
			continue
		end

		-- A packet slot reserved both opportunities before any live record drained.
		WorkBudget.Take(work, "encodes")
		local payload, reason = self.codec.Encode(records)
		local sent = false

		if payload ~= nil then
			WorkBudget.Take(work, "sends")
			local completed, delivered, failure = pcall(self.dependencies.SendReliable, connection.player, payload)
			sent = completed and delivered
			reason = if completed then failure else "ActorSendFailed"
		end

		if self.connections[connection.player] ~= connection then
			continue
		end

		for _, delivery in deliveries do
			if self.connections[connection.player] ~= connection then
				break
			end

			local stream, record = delivery.stream, delivery.record
			stream.stagedOrder = nil

			if sent then
				if record.kind == "BaselineBegin" then
					connection.transfers[stream] = "Pending"
				elseif record.kind == "BaselineEnd" or record.kind == "ActorRemove" or record.kind == "ActorHalt" then
					if connection.transfers[stream] ~= nil then
						connection.transfers[stream] = nil
						connection.transferCount -= 1
					end
				end

				stream:Sent(record)
			else
				if connection.transfers[stream] == "Reserved" then
					connection.transfers[stream] = nil
					connection.transferCount -= 1
				end

				stream:Fault(reason or "ActorSendFailed")
			end

			if self.connections[connection.player] == connection then
				StreamOrder.Update(connection.orders, stream)
			end
		end
	end
end

function ActorAwarenessRuntime.Step(self: Runtime, maxBytes: number, maxRecords: number): ()
	if self.stepping or self.destroyed then
		return
	end

	assert(maxBytes < math.huge and maxRecords < math.huge, "InvalidReliableStepBudget")

	if maxBytes <= 0 or maxRecords <= 0 or self.active.count == 0 then
		self.work = nil

		return
	end

	self.work = WorkBudget.new(math.max(0, maxRecords), self.options.workLimits)
	self.epoch += 1
	self.stepping = true
	local success, failure = pcall(self._step, self, maxBytes, maxRecords)

	-- This epilogue also runs after an injected dependency throws. Nothing staged
	-- or blocked is reselected within its pump, and remaining active work survives.
	for _, stream in self.deferred do
		stream:ReleaseStaged()
		stream.active = false
		stream.dependencies.Activate(stream)
	end

	for _, connection in self.waiting do
		if connection.active.count > 0 or #connection.egress.queue > 0 then
			self:_queueConnection(connection)
		end
	end

	if self.destroyed then
		self.backlog:Destroy()
	end

	table.clear(self.deferred)
	table.clear(self.waiting)
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
	self.backlog:CloseRecipient(player)
	CommandEgress.Destroy(connection.egress)

	if connection.node ~= nil then
		ActiveQueue.Remove(connection.node)
	end

	if connection.captureNode ~= nil then
		ActiveQueue.Remove(connection.captureNode)
	end

	-- Streams own only tables/buffers, not observers or timers. Detach their owner
	-- atomically rather than traversing every aware Actor on a pump send fault.
	-- Staged deliveries retain the old owner only until this pump unwinds; Activate
	-- checks that identity, including close/re-Ready of the same Player.
	connection.transfers, connection.actors, connection.handles, connection.orders = {}, {}, {}, {}
	connection.active = ActiveQueue.new()
	connection.captures = ActiveQueue.new()
	connection.transferCount = 0
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

	-- A reentrant teardown must leave selected charges to the pump epilogue.
	if not self.stepping then
		self.backlog:Destroy()
	end

	table.clear(self.measuredRecords)
	self.active = ActiveQueue.new()
	self.captures = ActiveQueue.new()

	if not self.stepping then
		self.deferred, self.waiting = {}, {}
	end
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
		publication = publication,
		codec = codec,
		measuredRecords = setmetatable({}, { __mode = "k" }),
		dependencies = dependencies,
		options = options,
		backlog = Backlog.new(options.backlogLimits, options.maxBaselineBytes),
		connections = {},
		owners = {},
		players = {},
		models = {},
		projections = Projections.new(publication, catalog, codec),
		active = ActiveQueue.new(),
		captures = ActiveQueue.new(),
		deferred = {},
		waiting = {},
		epoch = 0,
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
				egress = CommandEgress.new(function(): ()
					self:_close(player)

					if dependencies.CloseConnection ~= nil then
						pcall(dependencies.CloseConnection, player, "CommandOutputExpired")
					end
				end),
				player = player,
				nextHandle = 1,
				actors = {},
				handles = {},
				active = ActiveQueue.new(),
				captures = ActiveQueue.new(),
				orders = {},
				waitEpoch = 0,
				transferCount = 0,
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

				if
					connection.egress.scope == nil
					or (#projected.patches == 0 and #projected.events == 0)
					or CommandEgress.AdmitPublication(connection.egress, self:_measureRecord(projected))
				then
					stream:Enqueue(projected, connection.egress.order)
				else
					stream:Fault("CommandFenceOverloaded")
				end
			end
		end)
	)

	-- The public interface erases private state; Luau treats metatable method receivers invariantly.
	return self :: Types.ActorAwarenessRuntime
end

return ActorAwarenessRuntime
