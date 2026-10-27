--!strict
local Types = require(script.Parent.types)
local Constants = require(script.Parent.utils.HintConstants)
local BufferUtils = require(script.Parent.utils.CodecBufferUtils)
local Value = require(script.Parent.utils.CommandValue)

local HintCodec = {}

local function counter(value: any): boolean
	return type(value) == "number" and value > 0 and BufferUtils.IsOffset(value, Constants.MAX_COUNTER)
end

function HintCodec.Compile(protocol: Types.ClientProtocol, direction: Types.HintDirection?): Types.HintCodec
	local hints: { [number]: Types.ClientHint } = protocol.hintsByCode or {}
	local expectedDirection: Types.HintDirection = direction or "ClientToServer"

	return {
		EncodeRecord = function(record: Types.HintRecord): (buffer?, string?)
			local hint = hints[record.hintCode]

			if hint == nil then
				return nil, "UnknownHintCode"
			elseif hint.direction ~= expectedDirection then
				return nil, "HintDirectionMismatch"
			elseif
				(hint.target == "Actor" and not counter(record.targetHandle))
				or (hint.target == "None" and record.targetHandle ~= nil)
			then
				return nil, "HintTargetMismatch"
			elseif
				(hint.mode == "Latest" and not counter(record.sequence))
				or (hint.mode == "Pulse" and record.sequence ~= nil)
			then
				return nil, "InvalidHintSequence"
			end

			local size, reason = hint.payloadCodec.Measure(record.payload)

			if size == nil then
				return nil, reason
			end

			local bytes = Constants.RecordBytes(size, hint.target, hint.mode)

			if bytes + Constants.PACKET_HEADER_BYTES > Constants.MAX_PACKET_BYTES then
				return nil, "HintRecordTooLarge"
			end

			local destination = buffer.create(bytes)
			buffer.writeu16(destination, 0, hint.code)
			local offset = 2

			if hint.target == "Actor" then
				buffer.writeu32(destination, offset, record.targetHandle :: number)
				offset += 4
			end

			if hint.mode == "Latest" then
				buffer.writeu32(destination, offset, record.sequence :: number)
				offset += 4
			end

			local finished, writeReason = hint.payloadCodec.Write(record.payload, destination, offset)

			if finished ~= bytes then
				return nil, writeReason or "MalformedHintPayload"
			end

			return destination, nil
		end,
		Pack = function(records: { buffer }): (buffer?, string?)
			local size = Constants.PACKET_HEADER_BYTES

			if #records == 0 or #records > Constants.MAX_RECORDS then
				return nil, "HintPacketFull"
			end

			for _, record in records do
				size += buffer.len(record)
			end

			if size > Constants.MAX_PACKET_BYTES then
				return nil, "HintPacketFull"
			end

			local packet = buffer.create(size)
			buffer.writeu8(packet, 0, Constants.PACKET_KIND)
			buffer.writeu32(packet, 1, size)
			buffer.writeu32(packet, 5, #records)
			local offset = Constants.PACKET_HEADER_BYTES

			for _, record in records do
				buffer.copy(packet, offset, record)
				offset += buffer.len(record)
			end

			return packet, nil
		end,
		Open = function(payload: any): (Types.HintCursor?, string?)
			if
				typeof(payload) ~= "buffer"
				or buffer.len(payload) < Constants.PACKET_HEADER_BYTES
				or buffer.len(payload) > Constants.MAX_PACKET_BYTES
				or buffer.readu8(payload, 0) ~= Constants.PACKET_KIND
				or buffer.readu32(payload, 1) ~= buffer.len(payload)
			then
				return nil, "MalformedHintPacket"
			end

			local count = buffer.readu32(payload, 5)

			if
				count == 0
				or count > Constants.MAX_RECORDS
				or count * 2 > buffer.len(payload) - Constants.PACKET_HEADER_BYTES
			then
				return nil, "MalformedHintPacket"
			end

			return { source = payload, offset = Constants.PACKET_HEADER_BYTES, remaining = count }, nil
		end,
		Read = function(cursor: Types.HintCursor): (Types.HintRecord?, string?)
			local source, offset, limit = cursor.source, cursor.offset, buffer.len(cursor.source)

			if cursor.remaining <= 0 or offset + 2 > limit then
				return nil, "MalformedHintPacket"
			end

			local code = buffer.readu16(source, offset)
			local hint = hints[code]

			if hint == nil then
				return nil, "UnknownHintCode"
			elseif hint.direction ~= expectedDirection then
				return nil, "HintDirectionMismatch"
			end

			offset += 2
			local handle: number? = nil
			local sequence: number? = nil

			if hint.target == "Actor" then
				if offset + 4 > limit then
					return nil, "MalformedHintPacket"
				end

				handle = buffer.readu32(source, offset)
				offset += 4

				if handle == 0 then
					return nil, "HintTargetMismatch"
				end
			end

			if hint.mode == "Latest" then
				if offset + 4 > limit then
					return nil, "MalformedHintPacket"
				end

				sequence = buffer.readu32(source, offset)
				offset += 4

				if sequence == 0 then
					return nil, "InvalidHintSequence"
				end
			end

			local payload, nextOffset, reason = hint.payloadCodec.Read(source, offset, limit)

			if nextOffset == nil then
				return nil, reason or "MalformedHintPayload"
			elseif cursor.remaining == 1 and nextOffset ~= limit then
				return nil, "MalformedHintPacket"
			end

			cursor.offset, cursor.remaining = nextOffset, cursor.remaining - 1

			return table.freeze({
				hintCode = code,
				targetHandle = handle,
				sequence = sequence,
				payload = Value.Freeze(payload),
			}),
				nil
		end,
	}
end

return HintCodec
