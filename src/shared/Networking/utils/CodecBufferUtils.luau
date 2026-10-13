--!strict
local CodecBufferUtils = {}

local U32_BASE: number = 4294967296
local MAX_SAFE_INTEGER: number = 9007199254740991

function CodecBufferUtils.IsOffset(value: number, maximum: number): boolean
	return value >= 0 and value <= maximum and value % 1 == 0
end

function CodecBufferUtils.Width(maximum: number): number
	if maximum <= 255 then
		return 1
	end
	if maximum <= 65535 then
		return 2
	end
	if maximum < U32_BASE then
		return 4
	end
	return 8
end

function CodecBufferUtils.WriteUnsigned(destination: buffer, offset: number, value: number, width: number): number
	if width == 1 then
		buffer.writeu8(destination, offset, value)
	elseif width == 2 then
		buffer.writeu16(destination, offset, value)
	elseif width == 4 then
		buffer.writeu32(destination, offset, value)
	else
		buffer.writeu32(destination, offset, value % U32_BASE)
		buffer.writeu32(destination, offset + 4, math.floor(value / U32_BASE))
	end
	return offset + width
end

function CodecBufferUtils.ReadUnsigned(source: buffer, offset: number, width: number): number?
	if width == 1 then
		return buffer.readu8(source, offset)
	end
	if width == 2 then
		return buffer.readu16(source, offset)
	end
	if width == 4 then
		return buffer.readu32(source, offset)
	end
	local value: number = buffer.readu32(source, offset) + buffer.readu32(source, offset + 4) * U32_BASE
	return if value <= MAX_SAFE_INTEGER then value else nil
end

return CodecBufferUtils
