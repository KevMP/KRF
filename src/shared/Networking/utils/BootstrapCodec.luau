--!strict
local Types = require(script.Parent.Parent.types)
local Constants = require(script.Parent.ProtocolConstants)
local BufferUtils = require(script.Parent.CodecBufferUtils)

type Writer = { destination: buffer?, offset: number }
type Reader = { source: buffer, offset: number, limit: number }

local kinds: { string } = {
	"Boolean",
	"U8",
	"U16",
	"U32",
	"I8",
	"I16",
	"I32",
	"F32",
	"F64",
	"String",
	"Enum",
	"Optional",
	"Struct",
	"Array",
	"Map",
}

local kindCodes: { [string]: number } = {}

for index: number, kind: string in kinds do
	kindCodes[kind] = index - 1
end

local function reserve(writer: Writer, count: number): number
	if count > Constants.MAX_BOOTSTRAP_BYTES - writer.offset then
		error("BootstrapTooLarge", 0)
	end

	local offset: number = writer.offset

	writer.offset += count

	return offset
end

local function writeUnsigned(writer: Writer, value: number, width: number): ()
	if not BufferUtils.IsOffset(value, if width == 8 then 9007199254740991 else 2 ^ (width * 8) - 1) then
		error("InvalidProtocolManifest", 0)
	end

	local offset: number = reserve(writer, width)

	if writer.destination ~= nil then
		BufferUtils.WriteUnsigned(writer.destination, offset, value, width)
	end
end

local function writeString(writer: Writer, value: string): ()
	writeUnsigned(writer, #value, 4)
	local offset: number = reserve(writer, #value)

	if writer.destination ~= nil then
		buffer.writestring(writer.destination, offset, value)
	end
end

local function writeSchema(writer: Writer, schema: Types.SchemaDefinition, depth: number): ()
	if depth > 128 then
		error("InvalidProtocolManifest", 0)
	end

	local code: number? = kindCodes[schema.kind]

	if code == nil then
		error("UnsupportedSchema", 0)
	end

	writeUnsigned(writer, code, 1)

	if schema.kind == "String" then
		writeUnsigned(writer, schema.maxBytes, 8)
	elseif schema.kind == "Enum" then
		writeUnsigned(writer, #schema.values, 4)

		for _, value: string in schema.values do
			writeString(writer, value)
		end
	elseif schema.kind == "Optional" then
		writeSchema(writer, schema.inner, depth + 1)
	elseif schema.kind == "Struct" then
		local names: { string } = {}

		for name: string in schema.fields do
			table.insert(names, name)
		end

		table.sort(names)
		writeUnsigned(writer, #names, 4)

		for _, name: string in names do
			writeString(writer, name)
			writeSchema(writer, schema.fields[name], depth + 1)
		end
	elseif schema.kind == "Array" then
		writeUnsigned(writer, schema.maxLength, 8)
		writeSchema(writer, schema.element, depth + 1)
	elseif schema.kind == "Map" then
		writeUnsigned(writer, schema.maxEntries, 8)
		writeSchema(writer, schema.key, depth + 1)
		writeSchema(writer, schema.value, depth + 1)
	end
end

local function writeManifest(writer: Writer, manifest: Types.ProtocolManifest): ()
	writeUnsigned(writer, manifest.version, 2)
	writeUnsigned(writer, #manifest.domains, 4)

	for _, domain: Types.ManifestDomain in manifest.domains do
		writeString(writer, domain.id)
		writeUnsigned(writer, domain.code, 2)
		writeSchema(writer, domain.state, 1)
		writeUnsigned(writer, #domain.events, 4)

		for _, event: Types.ManifestEvent in domain.events do
			writeString(writer, event.id)
			writeUnsigned(writer, event.code, 2)
			writeSchema(writer, event.payload, 1)
		end
	end
end

local function take(reader: Reader, count: number): number
	if count > reader.limit - reader.offset then
		error("MalformedPacket", 0)
	end

	local offset: number = reader.offset

	reader.offset += count

	return offset
end

local function readUnsigned(reader: Reader, width: number): number
	local value: number? = BufferUtils.ReadUnsigned(reader.source, take(reader, width), width)

	if value == nil then
		error("MalformedPacket", 0)
	end

	return value
end

local function readCount(reader: Reader, minimumEntryBytes: number): number
	local count: number = readUnsigned(reader, 4)

	if count > math.floor((reader.limit - reader.offset) / minimumEntryBytes) then
		error("MalformedPacket", 0)
	end

	return count
end

local function readString(reader: Reader): string
	local length: number = readUnsigned(reader, 4)

	return buffer.readstring(reader.source, take(reader, length), length)
end

local function readSchema(reader: Reader, depth: number): Types.SchemaDefinition
	if depth > 128 then
		error("MalformedPacket", 0)
	end

	local kind: string? = kinds[readUnsigned(reader, 1) + 1]

	if kind == nil then
		error("UnsupportedSchema", 0)
	end

	if kind == "String" then
		return { kind = "String", maxBytes = readUnsigned(reader, 8) }
	elseif kind == "Enum" then
		local count: number = readCount(reader, 4)
		local values: { string } = {}

		for _ = 1, count do
			table.insert(values, readString(reader))
		end

		return { kind = "Enum", values = values }
	elseif kind == "Optional" then
		return { kind = "Optional", inner = readSchema(reader, depth + 1) }
	elseif kind == "Struct" then
		local count: number = readCount(reader, 5)
		local fields: { [string]: Types.SchemaDefinition } = {}

		for _ = 1, count do
			local name: string = readString(reader)

			if fields[name] ~= nil then
				error("MalformedPacket", 0)
			end

			fields[name] = readSchema(reader, depth + 1)
		end

		return { kind = "Struct", fields = fields }
	elseif kind == "Array" then
		local maximum: number = readUnsigned(reader, 8)

		return { kind = "Array", maxLength = maximum, element = readSchema(reader, depth + 1) }
	elseif kind == "Map" then
		local maximum: number = readUnsigned(reader, 8)
		local key: Types.SchemaDefinition = readSchema(reader, depth + 1)

		return { kind = "Map", maxEntries = maximum, key = key, value = readSchema(reader, depth + 1) }
	end

	return { kind = kind :: Types.PrimitiveKind }
end

local BootstrapCodec = {}

-- These private routines throw stable parse/budget reasons; ProtocolCodec owns
-- the protected boundary. Account for the packet opcode during measurement.
function BootstrapCodec.Encode(manifest: Types.ProtocolManifest, opcode: number): buffer
	local writer: Writer = { offset = 1 }
	writeManifest(writer, manifest)
	local destination: buffer = buffer.create(writer.offset)
	buffer.writeu8(destination, 0, opcode)
	local encoder: Writer = { destination = destination, offset = 1 }
	writeManifest(encoder, manifest)

	return destination
end

function BootstrapCodec.Decode(source: buffer): Types.ProtocolManifest
	local reader: Reader = { source = source, offset = 1, limit = buffer.len(source) }
	local version: number = readUnsigned(reader, 2)

	if version ~= Constants.PROTOCOL_VERSION then
		error("ProtocolMismatch", 0)
	end

	local domainCount: number = readCount(reader, 11)
	local domains: { Types.ManifestDomain } = {}

	for _ = 1, domainCount do
		local id: string = readString(reader)
		local code: number = readUnsigned(reader, 2)
		local state: Types.SchemaDefinition = readSchema(reader, 1)
		local eventCount: number = readCount(reader, 7)
		local events: { Types.ManifestEvent } = {}

		for _ = 1, eventCount do
			local eventId: string = readString(reader)
			local eventCode: number = readUnsigned(reader, 2)
			table.insert(events, { id = eventId, code = eventCode, payload = readSchema(reader, 1) })
		end

		table.insert(domains, { id = id, code = code, state = state, events = events })
	end

	if reader.offset ~= reader.limit then
		error("MalformedPacket", 0)
	end

	return { version = version, domains = domains }
end

return BootstrapCodec
