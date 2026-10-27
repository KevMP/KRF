--!strict
local Types = require(script.Parent.Parent.types)
local ActorTypes = require(script.Parent.Parent.Parent.Actor.types)
local SharedNetworkingTypes = require(script.Parent.Parent.Parent.Parent.shared.Networking.types)
local Metrics = require(script.Parent.Parent.Parent.Parent.shared.Networking.utils.NetworkingMetrics)
local Streams = require(script.Parent.ActorRecipientStream)
local ActiveQueue = require(script.Parent.ActiveQueue)
local CommandEgress = require(script.Parent.CommandEgress)
local StreamOrder = require(script.Parent.ActorStreamOrder)
local Diagnostics = require(script.Parent.NetworkingDiagnosticsState)
type Stream = Streams.Stream

export type Connection = {
	diagnostics: SharedNetworkingTypes.DiagnosticCollector?,
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

local Connection = {}

-- The awareness map owns session identity. This module owns creation/detachment
-- of the session's indexes, result egress, transfer slots and observations.
function Connection.new(player: Player, now: (() -> number)?, onExpired: () -> ()): Connection
	local connection: Connection = {
		diagnostics = Diagnostics.GetConnection(player),
		egress = CommandEgress.new(onExpired, Diagnostics.GetConnection(player), now),
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

	Metrics.Adjust(connection.diagnostics, "readyConnections", 1)

	if connection.diagnostics ~= nil then
		connection.diagnostics:SetAgeSource("reliableEligibleQueueAgeSeconds", function(): number?
			local earliest: number? = nil
			local result = connection.egress.queue[1]

			if
				result ~= nil
				and result.payload ~= nil
				and not StreamOrder.HasWorkThrough(connection.orders, result.order)
			then
				earliest = result.queuedAt
			end

			for _, stream in connection.orders do
				local queuedAt = if result == nil or stream:HasWorkThrough(result.order)
					then stream:GetEligibleQueuedAt()
					else nil

				if queuedAt ~= nil then
					earliest = math.min(earliest or math.huge, queuedAt)
				end
			end

			return if earliest ~= nil then math.max(0, (now or os.clock)() - earliest) else nil
		end)
	end

	return connection
end

function Connection.UpdateOrder(connection: Connection, stream: Stream): ()
	local previous = #connection.orders
	StreamOrder.Update(connection.orders, stream)

	if #connection.orders ~= previous then
		Metrics.Set(connection.diagnostics, "reliableActiveStreams", #connection.orders)
	end
end

-- Caller removes the session identity first. Staged leases stay with the pump;
-- detachment must not traverse or release the old stream graph during a send.
function Connection.Close(connections: { [Player]: Connection }, player: Player, backlog: Types.ReliableBacklog): ()
	local connection = connections[player]

	if connection == nil then
		return
	end

	connections[player] = nil

	local owner = connection.diagnostics
	Metrics.Count(owner, "baselinesAbandoned", Metrics.Set(owner, "baselineGenerations", 0))
	Metrics.Count(owner, "recoveryAbandoned", Metrics.Set(owner, "recoveryStreams", 0))
	Metrics.Count(owner, "publicationRecordsAbandoned", Metrics.Set(owner, "publicationQueuedRecords", 0))
	Metrics.Set(owner, "publicationQueuedBytes", 0)
	Metrics.Set(owner, "awareStreams", 0)
	Metrics.Set(owner, "reliableActiveStreams", 0)
	Metrics.Set(owner, "reliableActiveConnections", 0)
	Metrics.Adjust(owner, "readyConnections", -1)

	if owner ~= nil then
		owner:SetAgeSource("reliableEligibleQueueAgeSeconds", nil)
	end

	backlog:CloseRecipient(connection.player)
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

return Connection
