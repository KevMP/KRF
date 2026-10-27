--!strict
local Types = require(script.Parent.types)
local SchemaCompiler = require(script.Parent.Parent.Parent.shared.Networking.utils.SchemaCompiler)
local Collections = require(script.Parent.Parent.Parent.shared.Networking.utils.SchemaCollectionUtils)
local Constants = require(script.Parent.Parent.Parent.shared.Networking.utils.HintConstants)

local HintRegistry = {}
local loaded = false
local byId: { [string]: Types.LoadedHintDefinition } = table.freeze({} :: { [string]: Types.LoadedHintDefinition })
local ordered: { Types.LoadedHintDefinition } = table.freeze({} :: { Types.LoadedHintDefinition })

local fields =
	{ id = true, direction = true, target = true, mode = true, payload = true, authorize = true, receive = true }

function HintRegistry.Prepare(definitions: { Types.HintDefinition }): (Types.PreparedHintCatalog?, string?)
	if loaded then
		return nil, "HintDefinitionsAlreadyLoaded"
	end

	if type(definitions) ~= "table" then
		return nil, "HintDefinitionsMustBeTable"
	end

	local count = Collections.GetArrayLength(definitions)

	if count == nil or count > Constants.MAX_HINTS then
		return nil, "HintDefinitionsMustBeBoundedArray"
	end

	local staged: { [string]: Types.LoadedHintDefinition } = {}
	local definitionsInOrder: { Types.LoadedHintDefinition } = {}

	for index = 1, count do
		local definition: any = rawget(definitions, index)

		if type(definition) ~= "table" then
			return nil, "HintDefinitionMustBeTable"
		end

		local id: any = rawget(definition, "id")

		if type(id) ~= "string" or id == "" then
			return nil, "HintIdInvalid"
		end

		if staged[id] ~= nil then
			return nil, "DuplicateHintId"
		end

		for field in next, definition do
			if type(field) ~= "string" or not fields[field] then
				return nil, "HintFieldUnknown"
			end
		end

		local direction: any = rawget(definition, "direction")
		local target: any = rawget(definition, "target")
		local mode: any = rawget(definition, "mode")

		if direction ~= "ClientToServer" and direction ~= "ServerToClient" then
			return nil, "HintDirectionInvalid"
		end

		if target ~= "None" and target ~= "Actor" then
			return nil, "HintTargetInvalid"
		end

		if mode ~= "Latest" and mode ~= "Pulse" then
			return nil, "HintModeInvalid"
		end

		local authorize: any = rawget(definition, "authorize")
		local receive: any = rawget(definition, "receive")

		if (direction == "ClientToServer" or authorize ~= nil) and type(authorize) ~= "function" then
			return nil, "HintAuthorizationRequired"
		end

		if (direction == "ClientToServer" or receive ~= nil) and type(receive) ~= "function" then
			return nil, "HintReceiverRequired"
		end

		local rawPayload: any = rawget(definition, "payload")
		local payload, reason = SchemaCompiler.Compile(rawPayload)

		if payload == nil then
			return nil, reason
		end

		if
			Constants.PACKET_HEADER_BYTES + Constants.RecordBytes(payload.maxEncodedBytes, target, mode)
			> Constants.MAX_PACKET_BYTES
		then
			return nil, "HintRecordTooLarge"
		end

		local owned: Types.LoadedHintDefinition = table.freeze({
			id = id,
			direction = direction,
			target = target,
			mode = mode,
			payload = payload,
			authorize = authorize,
			receive = receive,
		})

		staged[id] = owned
		table.insert(definitionsInOrder, owned)
	end

	table.sort(
		definitionsInOrder,
		function(first: Types.LoadedHintDefinition, second: Types.LoadedHintDefinition): boolean
			return first.id < second.id
		end
	)

	return table.freeze({
		definitionsById = table.freeze(staged),
		orderedDefinitions = table.freeze(definitionsInOrder),
	}),
		nil
end

function HintRegistry.Publish(catalog: Types.PreparedHintCatalog): (boolean, string?)
	if loaded then
		return false, "HintDefinitionsAlreadyLoaded"
	end

	byId, ordered, loaded = catalog.definitionsById, catalog.orderedDefinitions, true

	return true, nil
end

function HintRegistry.Get(id: string): Types.LoadedHintDefinition?
	return byId[id]
end

function HintRegistry.GetAll(): { Types.LoadedHintDefinition }
	return ordered
end

function HintRegistry.IsLoaded(): boolean
	return loaded
end

function HintRegistry._RollbackStartup(): ()
	loaded = false
	byId = table.freeze({} :: { [string]: Types.LoadedHintDefinition })
	ordered = table.freeze({} :: { Types.LoadedHintDefinition })
end

return table.freeze(HintRegistry) :: Types.HintRegistry
