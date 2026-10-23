--!strict
local Types = require(script.Parent.types)
local SharedTypes = require(script.Parent.Parent.Parent.shared.Networking.types)
local SchemaCompiler = require(script.Parent.Parent.Parent.shared.Networking.utils.SchemaCompiler)
local Collections = require(script.Parent.Parent.Parent.shared.Networking.utils.SchemaCollectionUtils)
local Constants = require(script.Parent.Parent.Parent.shared.Networking.utils.CommandConstants)

local CommandRegistry = {}
local loaded: boolean = false

local byId: { [string]: Types.LoadedCommandDefinition } =
	table.freeze({} :: { [string]: Types.LoadedCommandDefinition })

local ordered: { Types.LoadedCommandDefinition } = table.freeze({} :: { Types.LoadedCommandDefinition })

local fields: { [string]: boolean } =
	{ id = true, target = true, request = true, result = true, authorize = true, handle = true }

function CommandRegistry.Prepare(definitions: { Types.CommandDefinition }): (Types.PreparedCommandCatalog?, string?)
	if loaded then
		return nil, "CommandDefinitionsAlreadyLoaded"
	end

	if type(definitions) ~= "table" then
		return nil, "CommandDefinitionsMustBeTable"
	end

	local count: number? = Collections.GetArrayLength(definitions)

	if count == nil or count > Constants.MAX_COMMANDS then
		return nil, "CommandDefinitionsMustBeBoundedArray"
	end

	local staged: { [string]: Types.LoadedCommandDefinition } = {}
	local definitionsInOrder: { Types.LoadedCommandDefinition } = {}

	for index: number = 1, count do
		local definition: any = rawget(definitions, index)

		if type(definition) ~= "table" then
			return nil, "CommandDefinitionMustBeTable"
		end

		local id: any = rawget(definition, "id")

		if type(id) ~= "string" or id == "" then
			return nil, "CommandIdInvalid"
		end

		if staged[id] ~= nil then
			return nil, "DuplicateCommandId"
		end

		for field in next, definition do
			if type(field) ~= "string" or not fields[field] then
				return nil, "CommandFieldUnknown"
			end
		end

		local target: any = rawget(definition, "target")

		if target ~= "None" and target ~= "Actor" then
			return nil, "CommandTargetInvalid"
		end

		local authorize: any = rawget(definition, "authorize")
		local handle: any = rawget(definition, "handle")

		if type(authorize) ~= "function" then
			return nil, "CommandAuthorizationRequired"
		end

		if type(handle) ~= "function" then
			return nil, "CommandHandlerRequired"
		end

		local schemas: { [string]: SharedTypes.CompiledSchema } = {}

		for _, field: string in { "request", "result" } do
			local raw: any = rawget(definition, field)

			if raw ~= nil then
				local compiled: SharedTypes.CompiledSchema?, reason: string? = SchemaCompiler.Compile(raw)

				if compiled == nil then
					return nil, reason
				end

				if compiled.maxEncodedBytes > Constants.MAX_PAYLOAD_BYTES then
					return nil, "CommandPayloadTooLarge"
				end

				schemas[field] = compiled
			end
		end

		local owned: Types.LoadedCommandDefinition = table.freeze({
			id = id,
			target = target,
			request = schemas.request,
			result = schemas.result,
			authorize = authorize,
			handle = handle,
		})

		staged[id] = owned
		table.insert(definitionsInOrder, owned)
	end

	table.sort(
		definitionsInOrder,
		function(first: Types.LoadedCommandDefinition, second: Types.LoadedCommandDefinition): boolean
			return first.id < second.id
		end
	)

	return table.freeze({
		definitionsById = table.freeze(staged),
		orderedDefinitions = table.freeze(definitionsInOrder),
	}),
		nil
end

function CommandRegistry.Publish(catalog: Types.PreparedCommandCatalog): (boolean, string?)
	if loaded then
		return false, "CommandDefinitionsAlreadyLoaded"
	end

	byId = catalog.definitionsById
	ordered = catalog.orderedDefinitions
	loaded = true

	return true, nil
end

function CommandRegistry.Get(id: string): Types.LoadedCommandDefinition?
	return byId[id]
end

function CommandRegistry.GetAll(): { Types.LoadedCommandDefinition }
	return ordered
end

function CommandRegistry.IsLoaded(): boolean
	return loaded
end

function CommandRegistry._RollbackStartup(): ()
	loaded = false
	byId = table.freeze({} :: { [string]: Types.LoadedCommandDefinition })
	ordered = table.freeze({} :: { Types.LoadedCommandDefinition })
end

return CommandRegistry
