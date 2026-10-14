--!strict
local Types = require(script.Parent.ActorStreamTypes)
local ProtocolTypes = require(script.Parent.ProtocolTypes)
local Constants = require(script.Parent.ActorProtocolConstants)
local Bytes = require(script.Parent.utils.ActorBuffer)
local PatchCompiler = require(script.Parent.utils.ActorPatchCompiler)
local Collections = require(script.Parent.utils.SchemaCollectionUtils)

local ActorStreamCodec = {} :: Types.CodecModule

local kinds: { [string]: number } =
	{ BaselineBegin = 0, BaselineChunk = 1, BaselineEnd = 2, Commit = 3, ActorRemove = 4 }

local function protected<T>(callback: () -> T, fallback: string): (T?, string?)
	local success: boolean, result: any = pcall(callback)
	if success then
		return result, nil
	end
	if string.find(tostring(result), "ActorBaselineTooLarge", 1, true) then
		return nil, "ActorBaselineTooLarge"
	end
	for _, reason: string in
		{ "UnknownDomainCode", "UnknownEventCode", "InvalidActorPatch", "InvalidActorEvent", "MalformedActorPacket" }
	do
		if fallback ~= "InvalidActorBaseline" and string.find(tostring(result), reason, 1, true) then
			return nil, reason
		end
	end
	return nil, fallback
end

local function count(cursor: Bytes.Cursor, values: any): number
	local length: number? = Collections.GetArrayLength(values)
	assert(length ~= nil, cursor.context)
	Bytes.Charge(cursor, length)
	Bytes.Unsigned(cursor, length, 4)
	return length
end

local function readCount(cursor: Bytes.Cursor): number
	local length: number = Bytes.ReadUnsigned(cursor, 4)
	Bytes.Charge(cursor, length)
	return length
end

function ActorStreamCodec.Compile(protocol: ProtocolTypes.ClientProtocol, schemas: Types.SchemaCatalog): Types.Codec
	local plans: { [string]: PatchCompiler.Plan } = {}
	for id: string, schema in schemas do
		plans[id] = PatchCompiler.Compile(schema)
	end
	local function domain(cursor: Bytes.Cursor): ProtocolTypes.ClientDomain
		local found: ProtocolTypes.ClientDomain? = protocol.domainsByCode[Bytes.ReadUnsigned(cursor, 4)]
		assert(found ~= nil, "UnknownDomainCode")
		return found
	end
	local function writeRecord(cursor: Bytes.Cursor, record: Types.Record): ()
		assert(kinds[record.kind] ~= nil and record.handle > 0, "MalformedActorPacket")
		Bytes.Unsigned(cursor, kinds[record.kind], 1)
		Bytes.Unsigned(cursor, record.handle, 4)
		if record.kind == "BaselineBegin" then
			Bytes.Unsigned(cursor, record.generation, 4)
			Bytes.Unsigned(cursor, record.totalBytes, 4)
			Bytes.Unsigned(cursor, if record.actorId == nil then 0 else 1, 1)
			if record.actorId ~= nil then
				Bytes.String(cursor, record.actorId)
			end
		elseif record.kind == "BaselineChunk" then
			Bytes.Unsigned(cursor, record.generation, 4)
			Bytes.Unsigned(cursor, record.offset, 4)
			Bytes.Unsigned(cursor, buffer.len(record.bytes), 4)
			Bytes.Bytes(cursor, record.bytes)
		elseif record.kind == "BaselineEnd" then
			Bytes.Unsigned(cursor, record.generation, 4)
			Bytes.Unsigned(cursor, record.revision, 4)
		elseif record.kind == "Commit" then
			Bytes.Unsigned(cursor, record.revision, 4)
			cursor.context = "InvalidActorPatch"
			count(cursor, record.patches)
			for _, change: Types.DomainPatch in record.patches do
				local found: ProtocolTypes.ClientDomain? = protocol.domainsById[change.domainId]
				local plan: PatchCompiler.Plan? = plans[change.domainId]
				assert(found ~= nil and plan ~= nil, "UnknownDomainCode")
				Bytes.Unsigned(cursor, found.code, 4)
				plan.Write(cursor, change.patch)
			end
			cursor.context = "InvalidActorEvent"
			count(cursor, record.events)
			for _, event: Types.Event in record.events do
				local found: ProtocolTypes.ClientDomain? = protocol.domainsById[event.domainId]
				assert(found ~= nil, "UnknownDomainCode")
				local compiled: ProtocolTypes.ClientEvent? = found.eventsById[event.eventId]
				assert(compiled ~= nil, "UnknownEventCode")
				Bytes.Unsigned(cursor, found.code, 4)
				Bytes.Unsigned(cursor, compiled.code, 4)
				Bytes.Value(cursor, compiled.codec, event.payload)
			end
		end
		cursor.context = "MalformedActorPacket"
	end
	local function readRecord(cursor: Bytes.Cursor): Types.Record
		local kind: number = Bytes.ReadUnsigned(cursor, 1)
		local handle: number = Bytes.ReadUnsigned(cursor, 4)
		assert(handle > 0, "MalformedActorPacket")
		if kind == 0 then
			local generation: number = Bytes.ReadUnsigned(cursor, 4)
			local totalBytes: number = Bytes.ReadUnsigned(cursor, 4)
			local presence: number = Bytes.ReadUnsigned(cursor, 1)
			assert(presence <= 1, "MalformedActorPacket")
			return {
				kind = "BaselineBegin",
				handle = handle,
				generation = generation,
				totalBytes = totalBytes,
				actorId = if presence == 1 then Bytes.ReadString(cursor) else nil,
			}
		elseif kind == 1 then
			local generation: number = Bytes.ReadUnsigned(cursor, 4)
			local offset: number = Bytes.ReadUnsigned(cursor, 4)
			local length: number = Bytes.ReadUnsigned(cursor, 4)
			return {
				kind = "BaselineChunk",
				handle = handle,
				generation = generation,
				offset = offset,
				bytes = Bytes.ReadBytes(cursor, length),
			}
		elseif kind == 2 then
			return {
				kind = "BaselineEnd",
				handle = handle,
				generation = Bytes.ReadUnsigned(cursor, 4),
				revision = Bytes.ReadUnsigned(cursor, 4),
			}
		elseif kind == 3 then
			local revision: number = Bytes.ReadUnsigned(cursor, 4)
			local patches: { Types.DomainPatch } = {}
			local events: { Types.Event } = {}
			cursor.context = "InvalidActorPatch"
			for _ = 1, readCount(cursor) do
				local found: ProtocolTypes.ClientDomain = domain(cursor)
				local plan: PatchCompiler.Plan? = plans[found.id]
				assert(plan ~= nil, "UnknownDomainCode")
				table.insert(patches, { domainId = found.id, patch = plan.Read(cursor) })
			end
			cursor.context = "InvalidActorEvent"
			for _ = 1, readCount(cursor) do
				local found: ProtocolTypes.ClientDomain = domain(cursor)
				local event: ProtocolTypes.ClientEvent? = found.eventsByCode[Bytes.ReadUnsigned(cursor, 4)]
				assert(event ~= nil, "UnknownEventCode")
				table.insert(
					events,
					{ domainId = found.id, eventId = event.id, payload = Bytes.ReadValue(cursor, event.codec) }
				)
			end
			cursor.context = "MalformedActorPacket"
			return { kind = "Commit", handle = handle, revision = revision, patches = patches, events = events }
		end
		assert(kind == 4, "MalformedActorPacket")
		return { kind = "ActorRemove", handle = handle }
	end
	local function writePacket(cursor: Bytes.Cursor, records: { Types.Record }): ()
		Bytes.Unsigned(cursor, Constants.PACKET_KIND, 1)
		Bytes.Unsigned(cursor, 0, 4)
		count(cursor, records)
		for _, record: Types.Record in records do
			writeRecord(cursor, record)
		end
	end
	return {
		Measure = function(records: { Types.Record }): (number?, string?)
			return protected(function(): number
				return Bytes.Measure(function(cursor: Bytes.Cursor)
					writePacket(cursor, records)
				end, Constants.MAX_PACKET_BYTES, "MalformedActorPacket")
			end, "MalformedActorPacket")
		end,
		Encode = function(records: { Types.Record }): (buffer?, string?)
			return protected(function(): buffer
				local payload: buffer = Bytes.Encode(function(cursor: Bytes.Cursor)
					writePacket(cursor, records)
				end, Constants.MAX_PACKET_BYTES, "MalformedActorPacket")
				buffer.writeu32(payload, 1, buffer.len(payload))
				return payload
			end, "MalformedActorPacket")
		end,
		Decode = function(payload: any): ({ Types.Record }?, string?)
			return protected(function(): { Types.Record }
				assert(typeof(payload) == "buffer", "MalformedActorPacket")
				local length: number = buffer.len(payload)
				assert(length >= 9 and length <= Constants.MAX_PACKET_BYTES, "MalformedActorPacket")
				local cursor: Bytes.Cursor = {
					data = payload,
					offset = 0,
					limit = length,
					remaining = Constants.MAX_WORK,
					context = "MalformedActorPacket",
				}
				assert(
					Bytes.ReadUnsigned(cursor, 1) == Constants.PACKET_KIND and Bytes.ReadUnsigned(cursor, 4) == length,
					"MalformedActorPacket"
				)
				local records: { Types.Record } = {}
				for _ = 1, readCount(cursor) do
					table.insert(records, readRecord(cursor))
				end
				assert(cursor.offset == length, "MalformedActorPacket")
				return records
			end, "MalformedActorPacket")
		end,
		EncodeBaseline = function(domains: { [string]: Types.DomainTruth }): (buffer?, string?)
			return protected(function(): buffer
				local ids: { string } = {}
				for id: string in next, domains do
					table.insert(ids, id)
				end
				table.sort(ids)
				return Bytes.Encode(function(cursor: Bytes.Cursor)
					Bytes.Charge(cursor, #ids)
					Bytes.Unsigned(cursor, #ids, 4)
					for _, id: string in ids do
						local found: ProtocolTypes.ClientDomain? = protocol.domainsById[id]
						assert(found ~= nil, "InvalidActorBaseline")
						Bytes.Unsigned(cursor, found.code, 4)
						Bytes.Value(cursor, found.stateCodec, domains[id].value)
					end
				end, Constants.MAX_BASELINE_BYTES, "InvalidActorBaseline")
			end, "InvalidActorBaseline")
		end,
		DecodeBaseline = function(payload: buffer): ({ [string]: Types.DomainTruth }?, string?)
			return protected(function(): { [string]: Types.DomainTruth }
				assert(
					typeof(payload) == "buffer" and buffer.len(payload) <= Constants.MAX_BASELINE_BYTES,
					"InvalidActorBaseline"
				)
				local cursor: Bytes.Cursor = {
					data = payload,
					offset = 0,
					limit = buffer.len(payload),
					remaining = Constants.MAX_WORK,
					context = "InvalidActorBaseline",
				}
				local domains: { [string]: Types.DomainTruth } = {}
				for _ = 1, readCount(cursor) do
					local found: ProtocolTypes.ClientDomain = domain(cursor)
					assert(domains[found.id] == nil, "InvalidActorBaseline")
					domains[found.id] = { value = Bytes.ReadValue(cursor, found.stateCodec) }
				end
				assert(cursor.offset == cursor.limit, "InvalidActorBaseline")
				return domains
			end, "InvalidActorBaseline")
		end,
	}
end

return ActorStreamCodec
