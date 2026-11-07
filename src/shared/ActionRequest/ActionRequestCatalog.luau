--!strict
local Types = require(script.Parent.types)
local NetworkingTypes = require(script.Parent.Parent.Networking.types)
local SchemaCompiler = require(script.Parent.Parent.Networking.utils.SchemaCompiler)
local CodecCompiler = require(script.Parent.Parent.Networking.CodecCompiler)
local Constants = require(script.Parent.utils.ActionRequestConstants)
local ActionContractTag = require(script.Parent.utils.ActionContractTag)

local ENTRY_FIELDS: { [string]: boolean } = {
	start = true,
	stop = true,
	allowInputInterrupt = true,
	requiresClientRelease = true,
	onDisconnect = true,
}

local DISCONNECT_POLICIES: { [string]: boolean } = { Keep = true, Interrupt = true }

table.freeze(ENTRY_FIELDS)
table.freeze(DISCONNECT_POLICIES)

-- Invalid and oversized schemas share one compile path so Start and Stop report
-- their own stable reasons.
local function compilePayload(definition: any, invalidReason: string): (Types.CompiledActionPayload?, string?)
	if definition == nil then
		return table.freeze({}), nil
	end

	local schema: NetworkingTypes.CompiledSchema? = SchemaCompiler.Compile(definition)

	if schema == nil then
		return nil, invalidReason
	elseif schema.maxEncodedBytes > Constants.MAX_PAYLOAD_BYTES then
		return nil, "ActionRequestPayloadTooLarge"
	end

	local codec: NetworkingTypes.CompiledCodec? = CodecCompiler.Compile(schema)

	if codec == nil then
		return nil, invalidReason
	end

	local payload: Types.CompiledActionPayload = { schema = schema, codec = codec }

	return table.freeze(payload), nil
end

local function compileStop(stop: any): (Types.CompiledActionPayload?, string?)
	if type(stop) ~= "table" then
		return nil, "ActionRequestStopInvalid"
	end

	for field: any in next, stop do
		if field ~= "parameters" then
			return nil, "ActionRequestStopInvalid"
		end
	end

	return compilePayload(rawget(stop, "parameters"), "ActionRequestStopSchemaInvalid")
end

local function isValidActionId(actionId: any): boolean
	return type(actionId) == "string" and actionId ~= "" and utf8.len(actionId) ~= nil
end

local function compileEntry(actionId: string, entry: any): (Types.CompiledActionRequest?, string?)
	if type(entry) ~= "table" then
		return nil, "ActionRequestSchemaMustBeTable"
	end

	for field: any in next, entry do
		if type(field) ~= "string" or not ENTRY_FIELDS[field] then
			return nil, "ActionRequestFieldUnknown"
		end
	end

	local start: Types.CompiledActionPayload?, startReason: string? =
		compilePayload(rawget(entry, "start"), "ActionRequestStartSchemaInvalid")

	if start == nil then
		return nil, startReason
	end

	local stop: Types.CompiledActionPayload? = nil
	local rawStop: any = rawget(entry, "stop")

	if rawStop ~= nil then
		local stopReason: string?
		stop, stopReason = compileStop(rawStop)

		if stop == nil then
			return nil, stopReason
		end
	end

	local allowInputInterrupt: any = rawget(entry, "allowInputInterrupt")
	local requiresClientRelease: any = rawget(entry, "requiresClientRelease")

	if
		(allowInputInterrupt ~= nil and type(allowInputInterrupt) ~= "boolean")
		or (requiresClientRelease ~= nil and type(requiresClientRelease) ~= "boolean")
	then
		return nil, "ActionRequestFlagInvalid"
	end

	local rawPolicy: any = rawget(entry, "onDisconnect")

	if rawPolicy ~= nil and (type(rawPolicy) ~= "string" or not DISCONNECT_POLICIES[rawPolicy]) then
		return nil, "ActionRequestDisconnectPolicyInvalid"
	end

	local onDisconnect: Types.ActionDisconnectPolicy = if rawPolicy == "Interrupt" then "Interrupt" else "Keep"

	-- Held Actions depend on a client release; losing that client must never leave them running.
	if requiresClientRelease == true then
		if stop == nil then
			return nil, "ActionRequestReleaseRequiresStop"
		elseif onDisconnect ~= "Interrupt" then
			return nil, "ActionRequestReleaseRequiresDisconnectInterrupt"
		end
	end

	local request: Types.CompiledActionRequest = {
		actionId = actionId,
		contractTag = ActionContractTag.Compute(
			actionId,
			start.schema,
			stop,
			allowInputInterrupt == true,
			requiresClientRelease == true,
			onDisconnect
		),
		start = start,
		stop = stop,
		allowInputInterrupt = allowInputInterrupt == true,
		requiresClientRelease = requiresClientRelease == true,
		onDisconnect = onDisconnect,
	}

	return table.freeze(request), nil
end

-- Both Server.Init and Client.Init compile the same replicated module, so every
-- validation is deterministic and independent of iteration order.
local ActionRequestCatalog: Types.ActionRequestCatalogModule = table.freeze({
	Compile = function(schemas: any): (Types.ActionRequestCatalog?, string?)
		if type(schemas) ~= "table" then
			return nil, "ActionRequestSchemasMustBeTable"
		end

		local actionIds: { string } = {}

		for actionId: any in next, schemas do
			if not isValidActionId(actionId) then
				return nil, "ActionRequestIdInvalid"
			elseif #actionId > Constants.MAX_ACTION_ID_BYTES then
				return nil, "ActionRequestIdTooLong"
			end

			table.insert(actionIds, actionId)
		end

		table.sort(actionIds)
		local requestsById: { [string]: Types.CompiledActionRequest } = {}

		for _, actionId: string in actionIds do
			local request: Types.CompiledActionRequest?, reason: string? =
				compileEntry(actionId, rawget(schemas, actionId))

			if request == nil then
				return nil, reason
			end

			requestsById[actionId] = request
		end

		local catalog: Types.ActionRequestCatalog = {
			actionIds = table.freeze(actionIds),
			requestsById = table.freeze(requestsById),
		}

		return table.freeze(catalog), nil
	end,
})

return ActionRequestCatalog
