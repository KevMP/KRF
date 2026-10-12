--!strict
local ReplicationTypes = require(script.Parent.types)
local NetworkingTypes = require(script.Parent.Parent.Parent.shared.Networking.types)
local SchemaCompiler = require(script.Parent.Parent.Parent.shared.Networking.utils.SchemaCompiler)
local SchemaCollectionUtils = require(script.Parent.Parent.Parent.shared.Networking.utils.SchemaCollectionUtils)

type ReplicationDomainDefinition = ReplicationTypes.ReplicationDomainDefinition
type LoadedReplicationDomainDefinition = ReplicationTypes.LoadedReplicationDomainDefinition
type PreparedReplicationDomainCatalog = ReplicationTypes.PreparedReplicationDomainCatalog
type CompiledSchema = NetworkingTypes.CompiledSchema

local ReplicationDomainRegistry = {} :: ReplicationTypes.InternalReplicationDomainRegistry
local isLoaded: boolean = false
local definitionsById: { [string]: LoadedReplicationDomainDefinition } =
	table.freeze({} :: { [string]: LoadedReplicationDomainDefinition })
local orderedDefinitions: { LoadedReplicationDomainDefinition } =
	table.freeze({} :: { LoadedReplicationDomainDefinition })

local domainFields: { [string]: boolean } = {
	id = true,
	state = true,
	events = true,
	audience = true,
	snapshot = true,
	observe = true,
}
local eventFields: { [string]: boolean } = { id = true, payload = true }
table.freeze(domainFields)
table.freeze(eventFields)

local function hasOnlyFields(definition: any, allowed: { [string]: boolean }): boolean
	for field in next, definition do
		if type(field) ~= "string" or not allowed[field] then
			return false
		end
	end
	return true
end

function ReplicationDomainRegistry.Prepare(
	definitions: { ReplicationDomainDefinition }
): (PreparedReplicationDomainCatalog?, string?)
	if isLoaded then
		return nil, "ReplicationDomainDefinitionsAlreadyLoaded"
	end
	if type(definitions) ~= "table" then
		return nil, "ReplicationDomainDefinitionsMustBeTable"
	end
	local count: number? = SchemaCollectionUtils.GetArrayLength(definitions)
	if count == nil then
		return nil, "ReplicationDomainDefinitionsMustBeArray"
	end
	local stagedById: { [string]: LoadedReplicationDomainDefinition } = {}
	local stagedOrdered: { LoadedReplicationDomainDefinition } = {}
	for index: number = 1, count do
		local definition: any = rawget(definitions, index)
		if type(definition) ~= "table" then
			return nil, "ReplicationDomainDefinitionMustBeTable"
		end
		local id: any = rawget(definition, "id")
		if id == nil then
			return nil, "ReplicationDomainIdMissing"
		end
		if type(id) ~= "string" then
			return nil, "ReplicationDomainIdMustBeString"
		end
		if id == "" then
			return nil, "ReplicationDomainIdCannotBeEmpty"
		end
		if stagedById[id] ~= nil then
			return nil, "DuplicateReplicationDomainId"
		end
		if not hasOnlyFields(definition, domainFields) then
			return nil, "ReplicationDomainFieldUnknown"
		end
		local snapshot: any = rawget(definition, "snapshot")
		if type(snapshot) ~= "function" then
			return nil, "ReplicationDomainSnapshotMustBeFunction"
		end
		local observe: any = rawget(definition, "observe")
		if observe ~= nil and type(observe) ~= "function" then
			return nil, "ReplicationDomainObserveMustBeFunction"
		end
		local audience: any = rawget(definition, "audience")
		if audience == nil then
			audience = "All"
		elseif audience ~= "All" and audience ~= "Owner" then
			return nil, "ReplicationDomainAudienceInvalid"
		end
		local rawState: any = rawget(definition, "state")
		if rawState == nil then
			return nil, "ReplicationDomainStateMissing"
		end
		local state: CompiledSchema?, stateReason: string? = SchemaCompiler.Compile(rawState)
		if state == nil then
			return nil, stateReason
		end
		local rawEvents: any = rawget(definition, "events")
		local events: { ReplicationTypes.LoadedReplicationEventDefinition } = {}
		if rawEvents ~= nil then
			local eventCount: number? = SchemaCollectionUtils.GetArrayLength(rawEvents)
			if eventCount == nil then
				return nil, "ReplicationEventsMustBeArray"
			end
			local eventIds: { [string]: boolean } = {}
			for eventIndex: number = 1, eventCount do
				local event: any = rawget(rawEvents, eventIndex)
				if type(event) ~= "table" then
					return nil, "ReplicationEventDefinitionMustBeTable"
				end
				local eventId: any = rawget(event, "id")
				if eventId == nil then
					return nil, "ReplicationEventIdMissing"
				end
				if type(eventId) ~= "string" then
					return nil, "ReplicationEventIdMustBeString"
				end
				if eventId == "" then
					return nil, "ReplicationEventIdCannotBeEmpty"
				end
				if eventIds[eventId] then
					return nil, "DuplicateReplicationEventId"
				end
				if not hasOnlyFields(event, eventFields) then
					return nil, "ReplicationEventFieldUnknown"
				end
				local rawPayload: any = rawget(event, "payload")
				if rawPayload == nil then
					return nil, "ReplicationEventPayloadMissing"
				end
				local payload: CompiledSchema?, payloadReason: string? = SchemaCompiler.Compile(rawPayload)
				if payload == nil then
					return nil, payloadReason
				end
				local loadedEvent: ReplicationTypes.LoadedReplicationEventDefinition =
					{ id = eventId, payload = payload }
				table.freeze(loadedEvent)
				table.insert(events, loadedEvent)
				eventIds[eventId] = true
			end
		end
		local loaded: LoadedReplicationDomainDefinition = {
			id = id,
			state = state,
			events = table.freeze(events),
			audience = audience,
			snapshot = snapshot,
			observe = observe,
		}
		table.freeze(loaded)
		stagedById[id] = loaded
		table.insert(stagedOrdered, loaded)
	end
	local prepared: PreparedReplicationDomainCatalog = {
		definitionsById = table.freeze(stagedById),
		orderedDefinitions = table.freeze(stagedOrdered),
	}
	return table.freeze(prepared), nil
end

function ReplicationDomainRegistry.Publish(catalog: PreparedReplicationDomainCatalog): (boolean, string?)
	if isLoaded then
		return false, "ReplicationDomainDefinitionsAlreadyLoaded"
	end
	definitionsById = catalog.definitionsById
	orderedDefinitions = catalog.orderedDefinitions
	isLoaded = true
	return true, nil
end

function ReplicationDomainRegistry.Get(domainId: string): LoadedReplicationDomainDefinition?
	return definitionsById[domainId]
end

function ReplicationDomainRegistry.GetAll(): { LoadedReplicationDomainDefinition }
	return orderedDefinitions
end

function ReplicationDomainRegistry.GetAllById(): { [string]: LoadedReplicationDomainDefinition }
	return definitionsById
end

function ReplicationDomainRegistry.IsLoaded(): boolean
	return isLoaded
end

function ReplicationDomainRegistry._resetForTests(): ()
	isLoaded = false
	definitionsById = table.freeze({} :: { [string]: LoadedReplicationDomainDefinition })
	orderedDefinitions = table.freeze({} :: { LoadedReplicationDomainDefinition })
end

return ReplicationDomainRegistry
