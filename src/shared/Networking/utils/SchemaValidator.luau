--!strict
local NetworkingTypes = require(script.Parent.Parent.types)
local SchemaCollectionUtils = require(script.Parent.SchemaCollectionUtils)
local SchemaPrimitives = require(script.Parent.SchemaPrimitives)

type CompiledSchema = NetworkingTypes.CompiledSchema

local SchemaValidator = {} :: NetworkingTypes.SchemaValidator

function SchemaValidator.Validate(schema: CompiledSchema, value: any): (boolean, string?)
	if schema.kind == "Optional" then
		if value == nil then
			return true, nil
		end
		return SchemaValidator.Validate(schema.inner, value)
	end
	if schema.kind == "Boolean" then
		return if type(value) == "boolean" then true else false,
			if type(value) == "boolean" then nil else "SchemaValueTypeInvalid"
	end
	local primitive: SchemaPrimitives.PrimitiveContract? = SchemaPrimitives[schema.kind]
	if primitive ~= nil then
		if type(value) ~= "number" then
			return false, "SchemaValueTypeInvalid"
		end
		if value ~= value or value == math.huge or value == -math.huge then
			return false, "SchemaNumberMustBeFinite"
		end
		if primitive.isInteger and value % 1 ~= 0 then
			return false, "SchemaIntegerMustBeIntegral"
		end
		if primitive.minimum ~= nil and (value < primitive.minimum or value > (primitive.maximum :: number)) then
			return false, if primitive.isInteger then "SchemaIntegerOutOfRange" else "SchemaF32OutOfRange"
		end
		return true, nil
	end
	if schema.kind == "String" then
		if type(value) ~= "string" then
			return false, "SchemaValueTypeInvalid"
		end
		if string.len(value) > schema.maxBytes then
			return false, "SchemaStringTooLong"
		end
		return true, nil
	elseif schema.kind == "Enum" then
		if type(value) ~= "string" then
			return false, "SchemaValueTypeInvalid"
		end
		if schema.ordinalsByValue[value] == nil then
			return false, "SchemaEnumValueInvalid"
		end
		return true, nil
	end
	if type(value) ~= "table" then
		return false, "SchemaValueTypeInvalid"
	end
	if schema.kind == "Struct" then
		for name in next, value do
			if type(name) ~= "string" or schema.fieldsByName[name] == nil then
				return false, "SchemaStructFieldUndeclared"
			end
		end
		for _, field: NetworkingTypes.CompiledField in schema.fields do
			local fieldValue: any = rawget(value, field.name)
			if fieldValue == nil and field.schema.kind ~= "Optional" then
				return false, "SchemaStructFieldMissing"
			end
			local valid: boolean, reason: string? = SchemaValidator.Validate(field.schema, fieldValue)
			if not valid then
				return false, reason
			end
		end
		return true, nil
	elseif schema.kind == "Array" then
		local length: number? = SchemaCollectionUtils.GetArrayLength(value)
		if length == nil then
			return false, "SchemaArrayMustBeDense"
		end
		if length > schema.maxLength then
			return false, "SchemaArrayTooLong"
		end
		for index: number = 1, length do
			local valid: boolean, reason: string? = SchemaValidator.Validate(schema.element, rawget(value, index))
			if not valid then
				return false, reason
			end
		end
		return true, nil
	elseif schema.kind == "Map" then
		local count: number = 0
		for _ in next, value do
			count += 1
			if count > schema.maxEntries then
				return false, "SchemaMapTooLarge"
			end
		end
		for entryKey, entryValue in next, value do
			local keyValid: boolean, keyReason: string? = SchemaValidator.Validate(schema.key, entryKey)
			if not keyValid then
				return false, keyReason
			end
			local valueValid: boolean, valueReason: string? = SchemaValidator.Validate(schema.value, entryValue)
			if not valueValid then
				return false, valueReason
			end
		end
		return true, nil
	end
	return false, "SchemaKindInvalid"
end

return SchemaValidator
