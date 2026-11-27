--!strict
local Types = require(script.Parent.types)
local Events = require(script.Parent.PresentationEvents)
local Sources = require(script.Parent.utils.PresentationSources)
local StateSources = require(script.Parent.utils.PresentationStateSources)
local Collections = require(script.Parent.Parent.Parent.shared.Networking.utils.SchemaCollectionUtils)

local PresentationRegistry = {}

type Index<Descriptor> = { [Descriptor]: { [string]: { Types.PresentationDefinition } } }

local function insert<Descriptor>(
	index: Index<Descriptor>,
	descriptor: Descriptor,
	sourceId: string,
	definition: Types.PresentationDefinition
): ()
	local bySourceId: { [string]: { Types.PresentationDefinition } } = index[descriptor] or {}

	index[descriptor] = bySourceId

	local definitions: { Types.PresentationDefinition } = bySourceId[sourceId] or {}

	bySourceId[sourceId] = definitions
	table.insert(definitions, definition)
end

local function freeze<Descriptor>(index: Index<Descriptor>): Index<Descriptor>
	for _, bySourceId in index do
		for _, definitions in bySourceId do
			table.freeze(definitions)
		end

		table.freeze(bySourceId)
	end

	return table.freeze(index)
end

function PresentationRegistry.Prepare(
	value: any,
	policies: Types.ActionPredictionPolicyCatalog?
): (Types.PresentationCatalog?, string?)
	local length: number? = Collections.GetArrayLength(value)

	if length == nil or getmetatable(value) ~= nil then
		return nil, "PresentationCatalogInvalid"
	end

	local events: Types.PresentationEventCatalog = {}
	local states: Types.PresentationStateCatalog = {}
	local predicted: { [string]: { Types.PresentationDefinition } } = {}
	local predictedPolicies: Types.ActionPredictionPolicyCatalog = {}
	local ids: { [string]: boolean } = {}

	for index: number = 1, length do
		local definition: any = rawget(value, index)

		if type(definition) ~= "table" or getmetatable(definition) ~= nil then
			return nil, "PresentationDefinitionInvalid"
		end

		for field: any in next, definition do
			if field ~= "id" and field ~= "entry" and field ~= "create" and field ~= "predict" then
				return nil, "PresentationDefinitionFieldUnknown"
			end
		end

		local id: any = definition.id
		local binding: any = definition.entry
		local create: any = definition.create
		local predict: any = definition.predict

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
			if field ~= "event" and field ~= "state" and field ~= "id" then
				return nil, "PresentationEntryFieldUnknown"
			end
		end

		local event: any = binding.event
		local state: any = binding.state
		local sourceId: any = binding.id

		if event ~= nil and state ~= nil then
			return nil, "PresentationEntryAmbiguous"
		elseif state ~= nil and not StateSources.IsEntry(state) then
			return nil, "PresentationEntryStateInvalid"
		elseif state == nil and not Sources.IsKnown(event) then
			return nil, "PresentationEntryEventInvalid"
		elseif type(sourceId) ~= "string" or sourceId == "" then
			return nil, "PresentationEntryIdInvalid"
		elseif predict ~= nil and type(predict) ~= "boolean" then
			return nil, "PresentationPredictInvalid"
		elseif predict == true and event ~= Events.Action.Started then
			return nil, "PresentationPredictEntryInvalid"
		elseif predict == true and (policies == nil or policies[sourceId] == nil) then
			return nil, "PresentationPredictionPolicyMissing"
		end

		ids[id] = true

		if state ~= nil then
			local ownedBinding: Types.PresentationStateEntryBinding = table.freeze({ state = state, id = sourceId })
			insert(states, state, sourceId, table.freeze({ id = id, entry = ownedBinding, create = create }))
		else
			local ownedBinding: Types.PresentationEntryBinding = table.freeze({ event = event, id = sourceId })

			local owned: Types.PresentationDefinition =
				table.freeze({ id = id, entry = ownedBinding, create = create, predict = predict == true })

			insert(events, event, sourceId, owned)

			if predict == true then
				local definitions: { Types.PresentationDefinition } = predicted[sourceId] or {}

				predicted[sourceId] = definitions
				predictedPolicies[sourceId] = (policies :: Types.ActionPredictionPolicyCatalog)[sourceId]
				table.insert(definitions, owned)
			end
		end
	end

	for _, definitions in predicted do
		table.freeze(definitions)
	end

	return table.freeze({
		events = freeze(events),
		states = freeze(states),
		predictions = table.freeze({
			policies = table.freeze(predictedPolicies),
			definitions = table.freeze(predicted),
		}),
	}),
		nil
end

return table.freeze(PresentationRegistry)
