--!strict
local Types = require(script.Parent.types)
local ContentId = require(script.Parent.utils.ContentId)

local ITEM_LIMIT: number = 64

local DESCRIPTOR_FIELDS: { [string]: boolean } = {
	kind = true,
	assetId = true,
}

table.freeze(DESCRIPTOR_FIELDS)

local Validator = {}

local function plainTable(value: unknown): boolean
	return type(value) == "table" and getmetatable(value :: any) == nil
end

local function countItems(items: { [unknown]: unknown }): (number?, string?)
	local count: number = 0
	local highest: number = 0

	for key: unknown in next, items do
		if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
			return nil, "PreloadItemsInvalid"
		end

		count += 1

		if count > ITEM_LIMIT then
			return nil, "PreloadItemLimit"
		end

		highest = math.max(highest, key)
	end

	if count == 0 then
		return nil, "PreloadItemsEmpty"
	elseif highest ~= count then
		return nil, "PreloadItemsInvalid"
	end

	return count, nil
end

function Validator.Descriptor(value: unknown): (Types.PreloadDescriptor?, string?)
	if not plainTable(value) then
		return nil, "PreloadItemInvalid"
	end

	local fields: { [unknown]: unknown } = value :: any

	for name: unknown in next, fields do
		if type(name) ~= "string" or not DESCRIPTOR_FIELDS[name] then
			return nil, "PreloadItemInvalid"
		end
	end

	local kind: unknown = fields.kind

	if kind ~= "Animation" and kind ~= "Sound" then
		return nil, "PreloadKindInvalid"
	end

	local assetId: string? = ContentId.Normalize(fields.assetId)

	if assetId == nil then
		return nil, "PreloadAssetIdInvalid"
	end

	return table.freeze({ kind = kind :: "Animation" | "Sound", assetId = assetId }), nil
end

function Validator.Request(items: unknown, onComplete: unknown): (Types.CompiledPreloadRequest?, string?)
	if not plainTable(items) then
		return nil, "PreloadItemsInvalid"
	end

	local list: { [unknown]: unknown } = items :: any
	local count: number?, countReason: string? = countItems(list)

	if count == nil then
		return nil, countReason
	end

	local instances: { Instance } = {}
	local descriptors: { Types.PreloadDescriptor } = {}
	local listed: { [Instance]: boolean } = {}
	local described: { [string]: boolean } = {}

	for index = 1, count do
		local item: unknown = list[index]

		if typeof(item) == "Instance" then
			local instance: Instance = item :: Instance

			if not listed[instance] then
				listed[instance] = true
				table.insert(instances, instance)
			end
		else
			local descriptor: Types.PreloadDescriptor?, reason: string? = Validator.Descriptor(item)

			if descriptor == nil then
				return nil, reason
			end

			local key: string = descriptor.kind .. " " .. descriptor.assetId

			if not described[key] then
				described[key] = true
				table.insert(descriptors, descriptor)
			end
		end
	end

	if onComplete ~= nil and type(onComplete) ~= "function" then
		return nil, "PreloadCallbackInvalid"
	end

	return table.freeze({ instances = table.freeze(instances), descriptors = table.freeze(descriptors) }), nil
end

return table.freeze(Validator)
