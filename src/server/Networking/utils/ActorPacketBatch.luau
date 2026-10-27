--!strict
local SharedNetworkingTypes = require(script.Parent.Parent.Parent.Parent.shared.Networking.types)
local Constants = require(script.Parent.Parent.Parent.Parent.shared.Networking.utils.ActorProtocolConstants)
local Metrics = require(script.Parent.Parent.Parent.Parent.shared.Networking.utils.NetworkingMetrics)
local Streams = require(script.Parent.ActorRecipientStream)
local Connections = require(script.Parent.ActorRecipientConnection)
local CommandEgress = require(script.Parent.CommandEgress)
local StreamOrder = require(script.Parent.ActorStreamOrder)
local WorkBudget = require(script.Parent.ReliableWorkBudget)
type Stream = Streams.Stream
type Connection = Connections.Connection

type Delivery = { stream: Stream, record: SharedNetworkingTypes.ActorStreamRecord, generation: number }

type Packet = {
	connection: Connection,
	bytes: number,
	records: { SharedNetworkingTypes.ActorStreamRecord },
	deliveries: { Delivery },
}

local Batch = {}
Batch.__index = Batch

type State = {
	codec: SharedNetworkingTypes.ActorStreamCodec,
	current: (Connection) -> boolean,
	send: (Player, buffer) -> (boolean, string?),
	close: (Player) -> (),
	closeTransport: ((Player, string) -> ())?,
	bytes: number,
	records: number,
	deliveryBudget: number,
	packets: { Packet },
	currentPackets: { [Connection]: Packet },
	reservedPackets: number,
}

export type Runtime = typeof(setmetatable({} :: State, Batch))

function Batch.new(
	codec: SharedNetworkingTypes.ActorStreamCodec,
	current: (Connection) -> boolean,
	send: (Player, buffer) -> (boolean, string?),
	close: (Player) -> (),
	closeTransport: ((Player, string) -> ())?,
	bytes: number,
	records: number
): Runtime
	return setmetatable({
		codec = codec,
		current = current,
		send = send,
		close = close,
		closeTransport = closeTransport,
		bytes = bytes,
		records = records,
		deliveryBudget = bytes,
		packets = {},
		currentPackets = {},
		reservedPackets = 0,
	}, Batch)
end

-- Results share the pump budget but never an Actor envelope. A staged Actor
-- packet blocks newer results until a later visit, preserving N9 fences.
function Batch.SendResult(self: Runtime, connection: Connection, work: WorkBudget.Budget): (boolean, boolean)
	local front = connection.egress.queue[1]
	local sentResult = false

	if front ~= nil and front.payload ~= nil and self.currentPackets[connection] == nil then
		if not WorkBudget.Take(work, "checks") then
			return false, false
		end

		if
			not StreamOrder.HasWorkThrough(connection.orders, front.order)
			and buffer.len(front.payload) <= self.bytes
			and work.used.sends + self.reservedPackets < work.limits.sends
		then
			local payload = front.payload
			WorkBudget.Take(work, "sends")
			local completed, sent = pcall(self.send, connection.player, payload)
			self.bytes -= buffer.len(payload)
			self.records -= 1
			sentResult = true

			if completed and sent then
				CommandEgress.Release(connection.egress, front)
			elseif self.current(connection) then
				self.close(connection.player)

				if self.closeTransport ~= nil then
					self.closeTransport(connection.player, "CommandResultSendFailed")
				end
			end
		end
	end

	return true, sentResult
end

function Batch.Stage(self: Runtime, connection: Connection, stream: Stream, work: WorkBudget.Budget): ()
	local packet = self.currentPackets[connection]
	local nextBytes = stream.scheduler:GetNextRecordBytes(stream.key)

	if packet ~= nil and nextBytes ~= nil and nextBytes > Constants.MAX_PACKET_BYTES - packet.bytes then
		packet = nil
	end

	local canStage = packet ~= nil
		or (work.used.sends + self.reservedPackets < work.limits.sends and self.reservedPackets < work.limits.encodes)

	if canStage then
		local boundary = connection.egress.queue[1]

		local available = math.min(self.bytes, Constants.MAX_PACKET_BYTES - (if packet ~= nil then packet.bytes else 0))

		stream.stagedOrder = stream:GetNextOrder()

		local staged = false

		local record, measuredBytes = stream:Prepare(
			available,
			connection.transfers[stream] ~= nil or connection.transferCount < Constants.MAX_PENDING_BASELINES,
			self.deliveryBudget,
			if boundary ~= nil then boundary.order else nil,
			work
		)

		if not self.current(connection) then
			stream.stagedOrder = nil

			return
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
					self.currentPackets[connection] = packet
					table.insert(self.packets, packet)
					self.reservedPackets += 1
				end

				assert(packet ~= nil, "Expected staged Actor packet")

				if record.kind == "BaselineBegin" and connection.transfers[stream] == nil then
					connection.transfers[stream] = "Reserved"
					connection.transferCount += 1
				end

				packet.bytes += size
				table.insert(packet.records, record)

				table.insert(packet.deliveries, { stream = stream, record = record, generation = stream.generation })

				staged = true
				self.bytes -= size
				self.records -= 1
			end
		end

		if not staged then
			Metrics.Count(connection.diagnostics, "reliableUnproductiveInspections", 1)
			stream.stagedOrder = nil

			if self.current(connection) then
				Connections.UpdateOrder(connection, stream)
			end
		end
	end

	if not canStage then
		Metrics.Count(connection.diagnostics, "reliableUnproductiveInspections", 1)
	end
end

local function validate(packet: Packet): ()
	local connection = packet.connection
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

			if retained ~= index then
				records[retained] = record
				deliveries[retained] = delivery
			end
		else
			stream.stagedOrder = nil

			if connection.transfers[stream] == "Reserved" then
				connection.transfers[stream] = nil
				connection.transferCount -= 1
			end

			Connections.UpdateOrder(connection, stream)
		end
	end

	for index = preparedCount, retained + 1, -1 do
		records[index], deliveries[index] = nil, nil
	end
end

function Batch._settle(self: Runtime, packet: Packet, sent: boolean, reason: string?): ()
	local connection, deliveries = packet.connection, packet.deliveries

	for _, delivery in deliveries do
		if not self.current(connection) then
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

		if self.current(connection) then
			Connections.UpdateOrder(connection, stream)
		end
	end
end

function Batch.Flush(self: Runtime, work: WorkBudget.Budget): ()
	for _, packet in self.packets do
		local connection = packet.connection

		work.connection = connection.diagnostics

		if not self.current(connection) then
			continue
		end

		validate(packet)

		if #packet.records == 0 then
			continue
		end

		WorkBudget.Take(work, "encodes")
		local payload, reason = self.codec.Encode(packet.records)
		local sent = false

		if payload ~= nil then
			WorkBudget.Take(work, "sends")
			local completed, delivered, failure = pcall(self.send, connection.player, payload)
			sent = completed and delivered
			reason = if completed then failure else "ActorSendFailed"
		end

		if self.current(connection) then
			self:_settle(packet, sent, reason)
		end
	end
end

return Batch
