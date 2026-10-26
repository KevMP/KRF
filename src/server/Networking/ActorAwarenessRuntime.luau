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
local Connections = require(script.Parent.utils.ActorRecipientConnection)
local Delivery = require(script.Parent.utils.ActorDeliveryScheduler)
local WorkBudget = require(script.Parent.utils.ReliableWorkBudget)
local Metrics = require(script.Parent.Parent.Parent.shared.Networking.utils.NetworkingMetrics)
local Diagnostics = require(script.Parent.utils.NetworkingDiagnosticsState)
local Backlog = require(script.Parent.utils.ReliableBacklog)

type Stream = Streams.Stream

type Connection = Connections.Connection

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
	delivery: Delivery.Runtime,
	backlog: Types.ReliableBacklog,
	disconnects: { () -> () },
	actorRemovedObservers: { (ActorTypes.Actor) -> () },
	destroyed: boolean,
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
		self.delivery:Queue(connection)
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
		Now = self.dependencies.Now,
		Current = function(): boolean
			return self.connections[connection.player] == connection
		end,
		DiscardProjection = function(projectedActor: ActorTypes.Actor, projection: Projections.Projection): ()
			self.projections:Discard(projectedActor, projection)
		end,
		GetOrder = function(): number
			return connection.egress.order
		end,
		GetEpoch = function(): number
			return self.delivery.epoch
		end,
		ClaimCapture = function(active: Stream, work: WorkBudget.Budget): boolean
			return self.delivery.captures:Claim(connection, active, work)
		end,
		YieldCapture = function(active: Stream): ()
			self.delivery.captures:Yield(connection, active)
		end,
		Anchor = function(
			projectedActor: ActorTypes.Actor,
			player: Player
		): (number?, Projections.Projection?, string?)
			return self.projections:Anchor(projectedActor, self.owners[projectedActor] == player)
		end,
		Project = function(
			projectedActor: ActorTypes.Actor,
			_player: Player,
			projection: Projections.Projection
		): (number?, Projections.Projection?, string?)
			return self.projections:Project(projectedActor, projection)
		end,
		Activate = function(active: Stream): ()
			self.delivery:Activate(connection, active)
		end,
		ReportFault = self.dependencies.ReportFault,
		MeasureRecord = function(commit: Types.PublicationFilteredCommit): number
			return self:_measureRecord(commit)
		end,
	})

	connection.nextHandle += 1
	connection.actors[actor] = stream
	connection.handles[stream.handle] = stream
	Metrics.Adjust(connection.diagnostics, "awareStreams", 1)
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
			stream:ResetRecovery()
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
		Metrics.Adjust(connection.diagnostics, "awareStreams", -1)
		connection.handles[stream.handle] = nil
		stream:Retire()
	end

	for _, callback in table.clone(self.actorRemovedObservers) do
		pcall(callback, actor)
	end
end

function ActorAwarenessRuntime.ObserveActorRemoved(self: Runtime, callback: (ActorTypes.Actor) -> ()): () -> ()
	table.insert(self.actorRemovedObservers, callback)

	return function(): ()
		local index = table.find(self.actorRemovedObservers, callback)

		if index ~= nil then
			table.remove(self.actorRemovedObservers, index)
		end
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

	local anchored: boolean = stream:Capture()

	return anchored,
		if anchored
			then nil
			else if stream.recapture and not stream.failed then "ActorBaselineCapacity" else "ActorStreamHalted"
end

function ActorAwarenessRuntime.Step(self: Runtime, maxBytes: number, maxRecords: number): ()
	if self.destroyed then
		return
	end

	self.delivery:Step(maxBytes, maxRecords)
end

function ActorAwarenessRuntime._close(self: Runtime, player: Player): ()
	Connections.Close(self.connections, player, self.backlog)
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
	table.clear(self.actorRemovedObservers)
	table.clear(self.owners)
	table.clear(self.players)
	table.clear(self.models)
	self.projections:Destroy()

	self.delivery:Destroy()
	table.clear(self.measuredRecords)
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

	local connections: { [Player]: Connection } = {}
	local backlog = Backlog.new(options.backlogLimits, options.maxBaselineBytes)

	local function close(player: Player): ()
		Connections.Close(connections, player, backlog)
	end

	local delivery = Delivery.new(codec, function(connection: Connection): boolean
		return connections[connection.player] == connection
	end, function(player: Player, payload: buffer): (boolean, string?)
		return dependencies.SendReliable(player, payload)
	end, function(player: Player, reason: string): ()
		if dependencies.CloseConnection ~= nil then
			dependencies.CloseConnection(player, reason)
		end
	end, options, backlog, close, Diagnostics.GetServer())

	local state: RuntimeState = {
		publication = publication,
		codec = codec,
		measuredRecords = setmetatable({}, { __mode = "k" }),
		dependencies = dependencies,
		options = options,
		backlog = backlog,
		connections = connections,
		owners = {},
		players = {},
		models = {},
		projections = Projections.new(publication, catalog, codec),
		delivery = delivery,
		disconnects = {},
		actorRemovedObservers = {},
		destroyed = false,
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

			local connection = Connections.new(player, dependencies.Now, function(): ()
				self:_close(player)

				if dependencies.CloseConnection ~= nil then
					pcall(dependencies.CloseConnection, player, "CommandOutputExpired")
				end
			end)

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
