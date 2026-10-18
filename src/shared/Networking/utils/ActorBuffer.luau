--!strict
local Types = require(script.Parent.Parent.types)
local Constants = require(script.Parent.ActorProtocolConstants)

export type Cursor = { data: buffer?, offset: number, limit: number, remaining: number, context: string }

local ActorBuffer = {}

function ActorBuffer.Charge(cursor: Cursor, count: number): ()
	assert(count >= 0 and count <= cursor.remaining, cursor.context)
	cursor.remaining -= count
end

local function valueWork(cursor: Cursor, value: any): ()
	ActorBuffer.Charge(cursor, 1)

	if type(value) == "table" then
		for key: any, item: any in next, value do
			valueWork(cursor, key)
			valueWork(cursor, item)
		end
	end
end

function ActorBuffer.Unsigned(cursor: Cursor, value: number, width: number): ()
	assert(
		type(value) == "number" and value >= 0 and value % 1 == 0 and value <= (if width == 1 then 255 else 4294967295),
		cursor.context
	)

	assert(width <= cursor.limit - cursor.offset, cursor.context)

	if cursor.data ~= nil then
		if width == 1 then
			buffer.writeu8(cursor.data, cursor.offset, value)
		else
			buffer.writeu32(cursor.data, cursor.offset, value)
		end
	end

	cursor.offset += width
end

function ActorBuffer.ReadUnsigned(cursor: Cursor, width: number): number
	assert(cursor.data ~= nil and width <= cursor.limit - cursor.offset, "MalformedActorPacket")

	local value: number = if width == 1
		then buffer.readu8(cursor.data, cursor.offset)
		else buffer.readu32(cursor.data, cursor.offset)

	cursor.offset += width

	return value
end

function ActorBuffer.Bytes(cursor: Cursor, value: buffer): ()
	local length: number = buffer.len(value)
	assert(length <= cursor.limit - cursor.offset, cursor.context)

	if cursor.data ~= nil then
		buffer.copy(cursor.data, cursor.offset, value)
	end

	cursor.offset += length
end

function ActorBuffer.ReadBytes(cursor: Cursor, length: number): buffer
	assert(cursor.data ~= nil and length <= cursor.limit - cursor.offset, "MalformedActorPacket")
	local value: buffer = buffer.create(length)
	buffer.copy(value, 0, cursor.data, cursor.offset, length)
	cursor.offset += length

	return value
end

function ActorBuffer.String(cursor: Cursor, value: string): ()
	assert(type(value) == "string" and #value > 0 and #value <= 128, cursor.context)
	ActorBuffer.Unsigned(cursor, #value, 4)
	assert(#value <= cursor.limit - cursor.offset, cursor.context)

	if cursor.data ~= nil then
		buffer.writestring(cursor.data, cursor.offset, value)
	end

	cursor.offset += #value
end

function ActorBuffer.ReadString(cursor: Cursor): string
	local length: number = ActorBuffer.ReadUnsigned(cursor, 4)

	assert(
		length > 0 and length <= 128 and length <= cursor.limit - cursor.offset and cursor.data ~= nil,
		"MalformedActorPacket"
	)

	local value: string = buffer.readstring(cursor.data, cursor.offset, length)

	cursor.offset += length

	return value
end

function ActorBuffer.Value(cursor: Cursor, codec: Types.CompiledCodec, value: any): ()
	valueWork(cursor, value)
	local size: number? = codec.Measure(value)
	assert(size ~= nil and size <= cursor.limit - cursor.offset, cursor.context)

	if cursor.data ~= nil then
		assert(codec.Write(value, cursor.data, cursor.offset) == cursor.offset + size, cursor.context)
	end

	cursor.offset += size
end

function ActorBuffer.ReadValue(cursor: Cursor, codec: Types.CompiledCodec): any
	assert(cursor.data ~= nil, "MalformedActorPacket")
	local value: any, nextOffset: number?, reason: string? = codec.Read(cursor.data, cursor.offset, cursor.limit)
	assert(nextOffset ~= nil, if reason == "CodecTruncated" then "MalformedActorPacket" else cursor.context)
	valueWork(cursor, value)
	cursor.offset = nextOffset

	return value
end

function ActorBuffer.Measure(write: (Cursor) -> (), maximum: number, context: string): number
	local measure: Cursor =
		{ data = nil, offset = 0, limit = math.huge, remaining = Constants.MAX_WORK, context = context }

	write(measure)
	assert(measure.offset <= maximum, if context == "InvalidActorBaseline" then "ActorBaselineTooLarge" else context)

	return measure.offset
end

function ActorBuffer.Encode(write: (Cursor) -> (), maximum: number, context: string): buffer
	local size: number = ActorBuffer.Measure(write, maximum, context)
	local destination: buffer = buffer.create(size)

	local cursor: Cursor =
		{ data = destination, offset = 0, limit = size, remaining = Constants.MAX_WORK, context = context }

	write(cursor)
	assert(cursor.offset == size, context)

	return destination
end

return ActorBuffer
