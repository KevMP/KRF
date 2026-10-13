--!strict
local NetworkingTypes = require(script.Parent.types)
local BufferUtils = require(script.Parent.utils.CodecBufferUtils)
local CollectionUtils = require(script.Parent.utils.SchemaCollectionUtils)
local Primitives = require(script.Parent.utils.SchemaPrimitives)

local CodecCompiler = {} :: NetworkingTypes.CodecCompiler

type EntryBudget = { remaining: number }
type Plan = {
	fixed: number?,
	maximum: number,
	minimum: number,
	measure: (any, EntryBudget) -> (number?, string?),
	write: (any, buffer, number) -> number,
	read: (buffer, number, number, EntryBudget) -> (any?, number?, string?),
}
type FieldPlan = { name: string, optional: boolean, plan: Plan }
type NumberIO = { read: (buffer, number) -> number, write: (buffer, number, number) -> () }
type EnumSchema = { read values: { string }, read ordinalsByValue: { [string]: number } }
type StringSchema = { read maxBytes: number }
type OptionalSchema = { read inner: NetworkingTypes.CompiledSchema }
type StructSchema = {
	read fields: { NetworkingTypes.CompiledField },
	read fieldsByName: { [string]: NetworkingTypes.CompiledSchema },
}

local numberIO: { [string]: NumberIO } = {
	U8 = { read = buffer.readu8, write = buffer.writeu8 },
	U16 = { read = buffer.readu16, write = buffer.writeu16 },
	U32 = { read = buffer.readu32, write = buffer.writeu32 },
	I8 = { read = buffer.readi8, write = buffer.writei8 },
	I16 = { read = buffer.readi16, write = buffer.writei16 },
	I32 = { read = buffer.readi32, write = buffer.writei32 },
	F32 = { read = buffer.readf32, write = buffer.writef32 },
	F64 = { read = buffer.readf64, write = buffer.writef64 },
}
-- A shared root budget bounds even nested collections of zero-byte records.
-- Encoding applies the same admission limit so every emitted value can decode.
local COLLECTION_ENTRY_BUDGET: number = 100000

local compile: (NetworkingTypes.CompiledSchema) -> Plan

local function compilePrimitive(schema: NetworkingTypes.CompiledSchema, primitive: Primitives.PrimitiveContract): Plan
	local width: number = primitive.maxEncodedBytes
	local io: NumberIO? = numberIO[schema.kind]
	local function validate(value: any): string?
		if io == nil then
			return if type(value) == "boolean" then nil else "SchemaValueTypeInvalid"
		end
		if type(value) ~= "number" then
			return "SchemaValueTypeInvalid"
		end
		if value ~= value or value == math.huge or value == -math.huge then
			return "SchemaNumberMustBeFinite"
		end
		if primitive.isInteger and value % 1 ~= 0 then
			return "SchemaIntegerMustBeIntegral"
		end
		if primitive.minimum ~= nil and (value < primitive.minimum or value > (primitive.maximum :: number)) then
			return if primitive.isInteger then "SchemaIntegerOutOfRange" else "SchemaF32OutOfRange"
		end
		return nil
	end
	return {
		fixed = width,
		maximum = width,
		minimum = width,
		measure = function(value: any, _budget: EntryBudget): (number?, string?)
			local reason: string? = validate(value)
			return if reason == nil then width else nil, reason
		end,
		write = function(value: any, destination: buffer, offset: number): number
			if io ~= nil then
				io.write(destination, offset, value)
			else
				buffer.writeu8(destination, offset, if value then 1 else 0)
			end
			return offset + width
		end,
		read = function(source: buffer, offset: number, limit: number, _budget: EntryBudget): (any?, number?, string?)
			if width > limit - offset then
				return nil, nil, "CodecTruncated"
			end
			if io == nil then
				local value: number = buffer.readu8(source, offset)
				if value > 1 then
					return nil, nil, "CodecBooleanInvalid"
				end
				return value == 1, offset + 1, nil
			end
			local value: number = io.read(source, offset)
			local reason: string? = validate(value)
			if reason ~= nil then
				return nil, nil, reason
			end
			return value, offset + width, nil
		end,
	}
end

local function compileEnum(schema: EnumSchema): Plan
	local width: number = BufferUtils.Width(#schema.values - 1)
	return {
		fixed = width,
		maximum = width,
		minimum = width,
		measure = function(value: any, _budget: EntryBudget): (number?, string?)
			if type(value) ~= "string" then
				return nil, "SchemaValueTypeInvalid"
			end
			if schema.ordinalsByValue[value] == nil then
				return nil, "SchemaEnumValueInvalid"
			end
			return width, nil
		end,
		write = function(value: any, destination: buffer, offset: number): number
			return BufferUtils.WriteUnsigned(destination, offset, schema.ordinalsByValue[value], width)
		end,
		read = function(source: buffer, offset: number, limit: number, _budget: EntryBudget): (any?, number?, string?)
			if width > limit - offset then
				return nil, nil, "CodecTruncated"
			end
			local ordinal: number? = BufferUtils.ReadUnsigned(source, offset, width)
			if ordinal == nil or ordinal >= #schema.values then
				return nil, nil, "CodecEnumOrdinalInvalid"
			end
			return schema.values[ordinal + 1], offset + width, nil
		end,
	}
end

local function compileString(schema: StringSchema): Plan
	local width: number = BufferUtils.Width(schema.maxBytes)
	return {
		maximum = width + schema.maxBytes,
		minimum = width,
		measure = function(value: any, _budget: EntryBudget): (number?, string?)
			if type(value) ~= "string" then
				return nil, "SchemaValueTypeInvalid"
			end
			if #value > schema.maxBytes then
				return nil, "SchemaStringTooLong"
			end
			return width + #value, nil
		end,
		write = function(value: any, destination: buffer, offset: number): number
			local nextOffset: number = BufferUtils.WriteUnsigned(destination, offset, #value, width)
			buffer.writestring(destination, nextOffset, value)
			return nextOffset + #value
		end,
		read = function(source: buffer, offset: number, limit: number, _budget: EntryBudget): (any?, number?, string?)
			if width > limit - offset then
				return nil, nil, "CodecTruncated"
			end
			local length: number? = BufferUtils.ReadUnsigned(source, offset, width)
			if length == nil or length > schema.maxBytes then
				return nil, nil, "SchemaStringTooLong"
			end
			local nextOffset: number = offset + width
			if length > limit - nextOffset then
				return nil, nil, "CodecTruncated"
			end
			return buffer.readstring(source, nextOffset, length), nextOffset + length, nil
		end,
	}
end

local function compileOptional(schema: OptionalSchema): Plan
	local inner: Plan = compile(schema.inner)
	return {
		fixed = if inner.maximum == 0 then 1 else nil,
		maximum = 1 + inner.maximum,
		minimum = 1,
		measure = function(value: any, budget: EntryBudget): (number?, string?)
			if value == nil then
				return 1, nil
			end
			local size: number?, reason: string? = inner.measure(value, budget)
			return if size ~= nil then size + 1 else nil, reason
		end,
		write = function(value: any, destination: buffer, offset: number): number
			buffer.writeu8(destination, offset, if value == nil then 0 else 1)
			return if value == nil then offset + 1 else inner.write(value, destination, offset + 1)
		end,
		read = function(source: buffer, offset: number, limit: number, budget: EntryBudget): (any?, number?, string?)
			if offset == limit then
				return nil, nil, "CodecTruncated"
			end
			local presence: number = buffer.readu8(source, offset)
			if presence == 0 then
				return nil, offset + 1, nil
			end
			if presence ~= 1 then
				return nil, nil, "CodecOptionalPresenceInvalid"
			end
			return inner.read(source, offset + 1, limit, budget)
		end,
	}
end

local function compileStruct(schema: StructSchema): Plan
	local fields: { FieldPlan } = {}
	local maximum: number = 0
	local minimum: number = 0
	local fixed: boolean = true
	for _, field: NetworkingTypes.CompiledField in schema.fields do
		local child: Plan = compile(field.schema)
		table.insert(fields, { name = field.name, optional = field.schema.kind == "Optional", plan = child })
		maximum += child.maximum
		minimum += child.minimum
		fixed = fixed and child.fixed ~= nil
	end
	return {
		fixed = if fixed then maximum else nil,
		maximum = maximum,
		minimum = minimum,
		measure = function(value: any, budget: EntryBudget): (number?, string?)
			if type(value) ~= "table" then
				return nil, "SchemaValueTypeInvalid"
			end
			for name in next, value do
				if type(name) ~= "string" or schema.fieldsByName[name] == nil then
					return nil, "SchemaStructFieldUndeclared"
				end
			end
			local total: number = 0
			for _, field: FieldPlan in fields do
				local childValue: any = rawget(value, field.name)
				if childValue == nil and not field.optional then
					return nil, "SchemaStructFieldMissing"
				end
				local size: number?, reason: string? = field.plan.measure(childValue, budget)
				if size == nil then
					return nil, reason
				end
				total += size
			end
			return total, nil
		end,
		write = function(value: any, destination: buffer, offset: number): number
			for _, field: FieldPlan in fields do
				offset = field.plan.write(rawget(value, field.name), destination, offset)
			end
			return offset
		end,
		read = function(source: buffer, offset: number, limit: number, budget: EntryBudget): (any?, number?, string?)
			local result: { [string]: any } = {}
			for _, field: FieldPlan in fields do
				local value: any, nextOffset: number?, reason: string? = field.plan.read(source, offset, limit, budget)
				if nextOffset == nil then
					return nil, nil, reason
				end
				result[field.name] = value
				offset = nextOffset
			end
			return result, offset, nil
		end,
	}
end

local function compileCollection(schema: NetworkingTypes.CompiledSchema): Plan
	assert(schema.kind == "Array" or schema.kind == "Map", "Unsupported compiled schema")
	local isArray: boolean = schema.kind == "Array"
	local valuePlan: Plan = compile(if schema.kind == "Array" then schema.element else schema.value)
	local keyPlan: Plan? = if schema.kind == "Map" then compile(schema.key) else nil
	local bound: number = if schema.kind == "Array" then schema.maxLength else schema.maxEntries
	local width: number = BufferUtils.Width(bound)
	local boundReason: string = if isArray then "SchemaArrayTooLong" else "SchemaMapTooLarge"
	local minimum: number = valuePlan.minimum + (if keyPlan ~= nil then keyPlan.minimum else 0)
	local maximum: number = valuePlan.maximum + (if keyPlan ~= nil then keyPlan.maximum else 0)
	return {
		maximum = width + maximum * bound,
		minimum = width,
		measure = function(value: any, budget: EntryBudget): (number?, string?)
			if type(value) ~= "table" then
				return nil, "SchemaValueTypeInvalid"
			end
			local count: number = 0
			if isArray then
				local length: number? = CollectionUtils.GetArrayLength(value)
				if length == nil then
					return nil, "SchemaArrayMustBeDense"
				end
				count = length
			else
				for _ in next, value do
					count += 1
					if count > bound then
						return nil, boundReason
					end
				end
			end
			if count > bound then
				return nil, boundReason
			end
			if count > budget.remaining then
				return nil, "CodecEncodeWorkExceeded"
			end
			budget.remaining -= count
			local total: number = width
			for entryKey: any, entryValue: any in next, value do
				if keyPlan ~= nil then
					local mapKey: Plan = keyPlan :: Plan
					local size: number?, reason: string? = mapKey.measure(entryKey, budget)
					if size == nil then
						return nil, reason
					end
					total += size
				end
				local size: number?, reason: string? = valuePlan.measure(entryValue, budget)
				if size == nil then
					return nil, reason
				end
				total += size
			end
			return total, nil
		end,
		write = function(value: any, destination: buffer, offset: number): number
			local count: number = 0
			for _ in next, value do
				count += 1
			end
			offset = BufferUtils.WriteUnsigned(destination, offset, count, width)
			if isArray then
				for index: number = 1, count do
					offset = valuePlan.write(rawget(value, index), destination, offset)
				end
			else
				assert(keyPlan ~= nil, "Map codec requires a key plan")
				for entryKey: any, entryValue: any in next, value do
					offset = keyPlan.write(entryKey, destination, offset)
					offset = valuePlan.write(entryValue, destination, offset)
				end
			end
			return offset
		end,
		read = function(source: buffer, offset: number, limit: number, budget: EntryBudget): (any?, number?, string?)
			if width > limit - offset then
				return nil, nil, "CodecTruncated"
			end
			local count: number? = BufferUtils.ReadUnsigned(source, offset, width)
			if count == nil or count > bound then
				return nil, nil, boundReason
			end
			offset += width
			if minimum > 0 and count > math.floor((limit - offset) / minimum) then
				return nil, nil, "CodecTruncated"
			end
			if count > budget.remaining then
				return nil, nil, "CodecDecodeWorkExceeded"
			end
			budget.remaining -= count
			local result: { [any]: any } = {}
			for index: number = 1, count do
				local entryKey: any = index
				if keyPlan ~= nil then
					local mapKey: Plan = keyPlan :: Plan
					local nextOffset: number?, reason: string?
					entryKey, nextOffset, reason = mapKey.read(source, offset, limit, budget)
					if nextOffset == nil then
						return nil, nil, reason
					end
					offset = nextOffset
					if result[entryKey] ~= nil then
						return nil, nil, "CodecMapDuplicateKey"
					end
				end
				local entryValue: any, nextOffset: number?, reason: string? =
					valuePlan.read(source, offset, limit, budget)
				if nextOffset == nil then
					return nil, nil, reason
				end
				if entryValue == nil then
					return nil, nil, "CodecCollectionEntryAbsent"
				end
				result[entryKey] = entryValue
				offset = nextOffset
			end
			return result, offset, nil
		end,
	}
end

compile = function(schema: NetworkingTypes.CompiledSchema): Plan
	local primitive: Primitives.PrimitiveContract? = Primitives[schema.kind]
	if primitive ~= nil then
		return compilePrimitive(schema, primitive)
	elseif schema.kind == "Enum" then
		return compileEnum(schema)
	elseif schema.kind == "String" then
		return compileString(schema)
	elseif schema.kind == "Optional" then
		return compileOptional(schema)
	elseif schema.kind == "Struct" then
		return compileStruct(schema)
	end
	return compileCollection(schema)
end

function CodecCompiler.Compile(schema: NetworkingTypes.CompiledSchema): (NetworkingTypes.CompiledCodec?, string?)
	local plan: Plan = compile(schema)
	local codec: NetworkingTypes.CompiledCodec = {
		fixedSizeBytes = plan.fixed,
		maxSizeBytes = plan.maximum,
		Measure = function(value: any): (number?, string?)
			return plan.measure(value, { remaining = COLLECTION_ENTRY_BUDGET })
		end,
		Write = function(value: any, destination: buffer, offset: number): (number?, string?)
			if not BufferUtils.IsOffset(offset, buffer.len(destination)) then
				return nil, "CodecWriteBoundsInvalid"
			end
			local size: number?, reason: string? = plan.measure(value, { remaining = COLLECTION_ENTRY_BUDGET })
			if size == nil then
				return nil, reason
			end
			if size > buffer.len(destination) - offset then
				return nil, "CodecBufferTooSmall"
			end
			return plan.write(value, destination, offset), nil
		end,
		Read = function(source: buffer, offset: number, limit: number): (any?, number?, string?)
			if not BufferUtils.IsOffset(limit, buffer.len(source)) or not BufferUtils.IsOffset(offset, limit) then
				return nil, nil, "CodecReadBoundsInvalid"
			end
			return plan.read(source, offset, limit, { remaining = COLLECTION_ENTRY_BUDGET })
		end,
	}
	table.freeze(codec)
	return codec :: NetworkingTypes.CompiledCodec?, nil
end

return CodecCompiler
