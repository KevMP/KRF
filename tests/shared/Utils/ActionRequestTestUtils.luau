--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF

local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local expect: any = JestGlobals.expect
local ActionRequestTypes = require(KRF.shared.ActionRequest.types)
local SharedNetworkingTypes = require(KRF.shared.Networking.types)
local Schema: SharedNetworkingTypes.Schema = require(KRF.shared.Networking.Schema)
local Catalog: ActionRequestTypes.ActionRequestCatalogModule = require(KRF.shared.ActionRequest.ActionRequestCatalog)
local SchemaCompiler = require(KRF.shared.Networking.utils.SchemaCompiler)
local CodecCompiler = require(KRF.shared.Networking.CodecCompiler)

local ActionRequestTestUtils = {}

-- The issue's representative consumer module: a typed Start, a held release-dependent
-- Action with an empty Stop, and a Technique with typed Start and Stop payloads.
function ActionRequestTestUtils.schemas(): ActionRequestTypes.ActionRequestSchemas
	local aim: SharedNetworkingTypes.SchemaDefinition =
		Schema.Struct({ x = Schema.F32, y = Schema.F32, z = Schema.F32 })

	return {
		["Combat.Fireball"] = { start = Schema.Struct({ aim = aim }) },
		["Movement.Sprint"] = {
			stop = {},
			allowInputInterrupt = true,
			requiresClientRelease = true,
			onDisconnect = "Interrupt",
		},
		["Technique.Cast"] = {
			start = Schema.Struct({ techniqueId = Schema.String(64), aim = aim }),
			stop = { parameters = Schema.Struct({ releaseAim = aim }) },
			allowInputInterrupt = true,
			onDisconnect = "Interrupt",
		},
	}
end

function ActionRequestTestUtils.compile(schemas: any): ActionRequestTypes.ActionRequestCatalog
	local catalog: ActionRequestTypes.ActionRequestCatalog?, reason: string? = Catalog.Compile(schemas)
	expect(reason).toBeNil()
	assert(catalog ~= nil, "Expected a compiled Action request catalog")

	return catalog
end

function ActionRequestTestUtils.request(
	catalog: ActionRequestTypes.ActionRequestCatalog,
	actionId: string
): ActionRequestTypes.CompiledActionRequest
	local request: ActionRequestTypes.CompiledActionRequest? = catalog.requestsById[actionId]
	assert(request ~= nil, "Expected a compiled request for " .. actionId)

	return request
end

local function payload(definition: SharedNetworkingTypes.SchemaDefinition?): ActionRequestTypes.CompiledActionPayload
	if definition == nil then
		return table.freeze({})
	end

	local schema: SharedNetworkingTypes.CompiledSchema?, reason: string? = SchemaCompiler.Compile(definition)
	assert(schema ~= nil, reason)
	local codec: SharedNetworkingTypes.CompiledCodec?, codecReason: string? = CodecCompiler.Compile(schema)
	assert(codec ~= nil, codecReason)

	return table.freeze({ schema = schema, codec = codec })
end

-- Hand-compiled so runtime contracts on either side do not depend on the shared catalog compiler.
-- Tags are fixed per sorted index; runtimes must use the catalog's own tag.
function ActionRequestTestUtils.catalog(
	schemas: ActionRequestTypes.ActionRequestSchemas
): ActionRequestTypes.ActionRequestCatalog
	local actionIds: { string } = {}
	local requestsById: { [string]: ActionRequestTypes.CompiledActionRequest } = {}

	for actionId: string in schemas do
		table.insert(actionIds, actionId)
	end

	table.sort(actionIds)

	for index: number, actionId: string in actionIds do
		local entry: ActionRequestTypes.ActionRequestSchema = schemas[actionId]

		local onDisconnect: ActionRequestTypes.ActionDisconnectPolicy = entry.onDisconnect or "Keep"

		local request: ActionRequestTypes.CompiledActionRequest = {
			actionId = actionId,
			contractTag = 1000 + index,
			start = payload(entry.start),
			stop = if entry.stop ~= nil then payload(entry.stop.parameters) else nil,
			allowInputInterrupt = entry.allowInputInterrupt == true,
			requiresClientRelease = entry.requiresClientRelease == true,
			onDisconnect = onDisconnect,
		}

		requestsById[actionId] = table.freeze(request)
	end

	return table.freeze({ actionIds = table.freeze(actionIds), requestsById = table.freeze(requestsById) })
end

-- The I5 wire format: the compiled inner codec written to an owned buffer, as a binary string.
function ActionRequestTestUtils.encode(compiled: ActionRequestTypes.CompiledActionPayload, value: any): string
	local codec: SharedNetworkingTypes.CompiledCodec? = compiled.codec

	if codec == nil then
		return ""
	end

	local size: number?, reason: string? = codec.Measure(value)
	assert(size ~= nil, reason)
	local destination: buffer = buffer.create(size)
	local written: number?, writeReason: string? = codec.Write(value, destination, 0)
	assert(written == size, writeReason)

	return buffer.tostring(destination)
end

return ActionRequestTestUtils
