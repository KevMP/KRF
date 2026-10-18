--!strict
local Types = require(script.Parent.Parent.types)
local Compiler = require(script.Parent.Parent.CodecCompiler)
local CollectionUtils = require(script.Parent.SchemaCollectionUtils)
local Bytes = require(script.Parent.ActorBuffer)

export type Plan = { Write: (Bytes.Cursor, Types.ActorPatch) -> (), Read: (Bytes.Cursor) -> Types.ActorPatch }

local ActorPatchCompiler = {}

function ActorPatchCompiler.Compile(schema: Types.CompiledSchema): Plan
	local compiled: Types.CompiledCodec? = Compiler.Compile(schema)
	assert(compiled ~= nil, "InvalidActorSchema")
	local codec: Types.CompiledCodec = compiled
	local fields: { { name: string, plan: Plan } } = {}
	local indices: { [string]: number } = {}
	local keyCodec: Types.CompiledCodec? = nil
	local entryCodec: Types.CompiledCodec? = nil

	if schema.kind == "Struct" then
		for index: number, field: Types.CompiledField in schema.fields do
			fields[index] = { name = field.name, plan = ActorPatchCompiler.Compile(field.schema) }
			indices[field.name] = index
		end
	elseif schema.kind == "Map" then
		keyCodec = Compiler.Compile(schema.key)
		entryCodec = Compiler.Compile(schema.value)
	end

	return {
		Write = function(cursor: Bytes.Cursor, patch: Types.ActorPatch): ()
			assert(type(patch) == "table", "InvalidActorPatch")

			if patch.kind == "Replace" then
				Bytes.Unsigned(cursor, 0, 1)
				Bytes.Value(cursor, codec, patch.value)
			elseif patch.kind == "Struct" and schema.kind == "Struct" then
				local count: number = 0

				for name: string in next, patch.fields do
					assert(indices[name] ~= nil, "InvalidActorPatch")
					count += 1
				end

				Bytes.Charge(cursor, count)
				Bytes.Unsigned(cursor, 1, 1)
				Bytes.Unsigned(cursor, count, 4)

				for index: number, field in fields do
					local change: Types.ActorPatch? = rawget(patch.fields, field.name)

					if change ~= nil then
						Bytes.Unsigned(cursor, index, 4)
						field.plan.Write(cursor, change)
					end
				end
			elseif patch.kind == "Map" and schema.kind == "Map" then
				assert(keyCodec ~= nil and entryCodec ~= nil, "InvalidActorSchema")
				local keys: { any } = {}

				for key: any in next, patch.entries do
					table.insert(keys, key)
				end

				local removed: number? = CollectionUtils.GetArrayLength(patch.removed)

				assert(
					#keys <= schema.maxEntries and removed ~= nil and removed <= schema.maxEntries,
					"InvalidActorPatch"
				)

				Bytes.Charge(cursor, #keys + removed)

				table.sort(keys, function(first: any, second: any): boolean
					return first < second
				end)

				Bytes.Unsigned(cursor, 2, 1)
				Bytes.Unsigned(cursor, #keys, 4)

				for _, key: any in keys do
					Bytes.Value(cursor, keyCodec, key)
					Bytes.Value(cursor, entryCodec, rawget(patch.entries, key))
				end

				Bytes.Unsigned(cursor, removed, 4)
				local seen: { [any]: boolean } = {}

				for _, key: any in patch.removed do
					assert(not seen[key] and rawget(patch.entries, key) == nil, "InvalidActorPatch")
					seen[key] = true
					Bytes.Value(cursor, keyCodec, key)
				end
			else
				error("InvalidActorPatch", 0)
			end
		end,
		Read = function(cursor: Bytes.Cursor): Types.ActorPatch
			local kind: number = Bytes.ReadUnsigned(cursor, 1)

			if kind == 0 then
				return { kind = "Replace", value = Bytes.ReadValue(cursor, codec) }
			end

			if kind == 1 and schema.kind == "Struct" then
				local count: number = Bytes.ReadUnsigned(cursor, 4)
				assert(count <= #fields, "InvalidActorPatch")
				Bytes.Charge(cursor, count)
				local changes: { [string]: Types.ActorPatch } = {}

				for _ = 1, count do
					local field = fields[Bytes.ReadUnsigned(cursor, 4)]
					assert(field ~= nil and changes[field.name] == nil, "InvalidActorPatch")
					changes[field.name] = field.plan.Read(cursor)
				end

				return { kind = "Struct", fields = changes }
			elseif kind == 2 and schema.kind == "Map" then
				assert(keyCodec ~= nil and entryCodec ~= nil, "InvalidActorSchema")
				local entries: { [any]: any } = {}
				local removed: { any } = {}
				local count: number = Bytes.ReadUnsigned(cursor, 4)
				assert(count <= schema.maxEntries, "InvalidActorPatch")
				Bytes.Charge(cursor, count)

				for _ = 1, count do
					local key: any = Bytes.ReadValue(cursor, keyCodec)
					assert(key ~= nil and entries[key] == nil, "InvalidActorPatch")
					local value: any = Bytes.ReadValue(cursor, entryCodec)
					assert(value ~= nil, "InvalidActorPatch")
					entries[key] = value
				end

				local removedCount: number = Bytes.ReadUnsigned(cursor, 4)
				assert(removedCount <= schema.maxEntries, "InvalidActorPatch")
				Bytes.Charge(cursor, removedCount)
				local seen: { [any]: boolean } = {}

				for _ = 1, removedCount do
					local key: any = Bytes.ReadValue(cursor, keyCodec)
					assert(key ~= nil and not seen[key] and entries[key] == nil, "InvalidActorPatch")
					seen[key] = true
					table.insert(removed, key)
				end

				return { kind = "Map", entries = entries, removed = removed }
			end

			error("InvalidActorPatch", 0)
		end,
	}
end

return ActorPatchCompiler
