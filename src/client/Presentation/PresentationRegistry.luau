--!strict
local Types = require(script.Parent.types)
local Sources = require(script.Parent.utils.PresentationSources)
local Collections = require(script.Parent.Parent.Parent.shared.Networking.utils.SchemaCollectionUtils)

local PresentationRegistry = {}

function PresentationRegistry.Prepare(value: any): (Types.PresentationCatalog?, string?)
	local length: number? = Collections.GetArrayLength(value)

	if length == nil or getmetatable(value) ~= nil then
		return nil, "PresentationCatalogInvalid"
	end

	local catalog: Types.PresentationCatalog = {}
	local ids: { [string]: boolean } = {}

	for index: number = 1, length do
		local definition: any = rawget(value, index)

		if type(definition) ~= "table" or getmetatable(definition) ~= nil then
			return nil, "PresentationDefinitionInvalid"
		end

		for field: any in next, definition do
			if field ~= "id" and field ~= "entry" and field ~= "create" then
				return nil, "PresentationDefinitionFieldUnknown"
			end
		end

		local id: any = definition.id
		local binding: any = definition.entry
		local create: any = definition.create

		if type(id) ~= "string" or id == "" then
			return nil, "PresentationIdInvalid"
		elseif ids[id] then
			return nil, "PresentationIdDuplicate"
		elseif type(create) ~= "function" then
			return nil, "PresentationCreateInvalid"
		elseif type(binding) ~= "table" or getmetatable(binding) ~= nil then
			return nil, "PresentationEntryInvalid"
		end

		for field: any in next, binding do
			if field ~= "event" and field ~= "id" then
				return nil, "PresentationEntryFieldUnknown"
			end
		end

		local event: any = binding.event
		local sourceId: any = binding.id

		if not Sources.IsKnown(event) then
			return nil, "PresentationEntryEventInvalid"
		elseif type(sourceId) ~= "string" or sourceId == "" then
			return nil, "PresentationEntryIdInvalid"
		end

		ids[id] = true

		local bySourceId: { [string]: { Types.PresentationDefinition } } = catalog[event] or {}

		catalog[event] = bySourceId

		local definitions: { Types.PresentationDefinition } = bySourceId[sourceId] or {}

		bySourceId[sourceId] = definitions

		local ownedBinding: Types.PresentationEntryBinding = table.freeze({ event = event, id = sourceId })

		local ownedDefinition: Types.PresentationDefinition =
			table.freeze({ id = id, entry = ownedBinding, create = create })

		table.insert(definitions, ownedDefinition)
	end

	for _, bySourceId in catalog do
		for _, definitions in bySourceId do
			table.freeze(definitions)
		end

		table.freeze(bySourceId)
	end

	return table.freeze(catalog), nil
end

return table.freeze(PresentationRegistry)
