--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local ServerTypes = require(KRF.server.types)
local ActionTypes = require(KRF.server.Action.types)
local TagTypes = require(KRF.server.Tags.types)
local ResourceTypes = require(KRF.server.Resource.types)
local NetworkingTypes = require(KRF.server.Networking.types)
local SharedTypes = require(KRF.shared.Networking.types)
local ActionRequestTypes = require(KRF.shared.ActionRequest.types)
local Server = require(KRF.server)
local Networking: NetworkingTypes.ServerNetworking = require(KRF.server.Networking.ServerNetworking)
local ProtocolConstants = require(KRF.shared.Networking.utils.ProtocolConstants)
local Schema: SharedTypes.Schema = require(KRF.shared.Networking.Schema)
local Commands = require(script.Parent.Parent.Utils.Networking.CommandRuntimeTestUtils)

local originalPrepare: typeof(Networking.Prepare) = Networking.Prepare
local bootstrapBytes: number? = nil

beforeEach(function()
	Server._ResetForTests()
	bootstrapBytes = nil

	Networking.Prepare = function(
		catalog: any,
		commands: NetworkingTypes.PreparedCommandCatalog?,
		hints: NetworkingTypes.PreparedHintCatalog?
	): (SharedTypes.PreparedProtocol?, string?)
		local protocol: SharedTypes.PreparedProtocol?, reason: string? = originalPrepare(catalog, commands, hints)

		if protocol ~= nil then
			bootstrapBytes = buffer.len(protocol.bootstrapBuffer)
		end

		return protocol, reason
	end
end)

afterEach(function()
	Networking.Prepare = originalPrepare
	Server._ResetForTests()
end)

type Workload = {
	actions: { ActionTypes.ActionFactory },
	schemas: ActionRequestTypes.ActionRequestSchemas,
	config: ServerTypes.ServerStartConfig,
}

-- Representative mixed catalog: 19-byte visible Action ids beside visible Tags,
-- Resources, consumer commands and hints, matching the issue's projection inputs.
local function workload(visibleActions: number, typedRequests: boolean): Workload
	local actions: { ActionTypes.ActionFactory } = {}
	local schemas: ActionRequestTypes.ActionRequestSchemas = {}
	local tags: { TagTypes.TagDefinition } = {}
	local resources: { ResourceTypes.ResourceDefinition } = {}
	local commands: { NetworkingTypes.CommandDefinition } = {}
	local hints: { NetworkingTypes.HintDefinition } = {}

	for index: number = 1, visibleActions do
		local actionId: string = string.format("Combat.Action%06d", index)

		table.insert(actions, function(): ActionTypes.ActionDefinition
			return { id = actionId, visibility = "ClientVisible", autoGrant = true }
		end)

		schemas[actionId] = if typedRequests
			then {
				start = Schema.Struct({ aim = Schema.Struct({ x = Schema.F32, y = Schema.F32, z = Schema.F32 }) }),
				stop = { parameters = Schema.Struct({ charge = Schema.U16 }) },
				allowInputInterrupt = true,
				onDisconnect = "Interrupt",
			}
			else {}
	end

	for index: number = 1, 64 do
		local tag: TagTypes.TagDefinition = {
			id = string.format("Status.Effect%04d", index),
			visibility = "ClientVisible",
			duplicateBehavior = "Ignore",
		}

		table.insert(tags, tag)
	end

	for index: number = 1, 8 do
		local resource: ResourceTypes.ResourceDefinition = {
			id = string.format("Resource.Pool%02d", index),
			visibility = "ClientVisible",
			max = { value = 100 },
		}

		table.insert(resources, resource)
	end

	for index: number = 1, 32 do
		local command: NetworkingTypes.CommandDefinition =
			Commands.definition(string.format("Game.Command%02d", index), "Actor")

		command.request = Schema.Struct({ choice = Schema.U8, label = Schema.String(32) })
		table.insert(commands, command)
	end

	for index: number = 1, 8 do
		local hint: NetworkingTypes.HintDefinition = {
			id = string.format("Game.Hint%02d", index),
			direction = "ServerToClient",
			target = "Actor",
			mode = "Latest",
			payload = Schema.Struct({ x = Schema.F32, y = Schema.F32 }),
		}

		table.insert(hints, hint)
	end

	return {
		actions = actions,
		schemas = schemas,
		config = {
			actions = actions,
			tags = tags,
			resources = resources,
			commands = commands,
			hints = hints,
			actionRequestSchemas = schemas,
		},
	}
end

local function start(config: ServerTypes.ServerStartConfig): (boolean, ServerTypes.StartupFailure?, number?)
	Server._ResetForTests()
	bootstrapBytes = nil
	local success: boolean, failure: ServerTypes.StartupFailure? = Server.Init(config)

	return success, failure, bootstrapBytes
end

for _, count: number in { 50, 200, 500, 800 } do
	it("starts a representative " .. count .. " visible Action catalog within the N9 bootstrap bound", function()
		local success: boolean, failure: ServerTypes.StartupFailure?, bytes: number? =
			start(workload(count, true).config)

		expect(failure).toBeNil()
		expect(success).toBe(true)
		assert(bytes ~= nil, "Expected a measured bootstrap")
		expect(bytes <= ProtocolConstants.MAX_BOOTSTRAP_BYTES).toBe(true)
	end)
end

it("keeps per-Action inner request schemas out of the N9 bootstrap", function()
	local typedSuccess: boolean, typedFailure: ServerTypes.StartupFailure?, typedBytes: number? =
		start(workload(200, true).config)

	expect(typedFailure).toBeNil()
	expect(typedSuccess).toBe(true)

	local plainSuccess: boolean, plainFailure: ServerTypes.StartupFailure?, plainBytes: number? =
		start(workload(200, false).config)

	expect(plainFailure).toBeNil()
	expect(plainSuccess).toBe(true)
	expect(typedBytes).toBe(plainBytes)
end)

it("adds only the three fixed command envelopes to the bootstrap when request schemas are supplied", function()
	local withRequests: Workload = workload(50, true)

	local requestSuccess: boolean, _requestFailure: ServerTypes.StartupFailure?, requestBytes: number? =
		start(withRequests.config)

	expect(requestSuccess).toBe(true)

	local withoutConfig: ServerTypes.ServerStartConfig = table.clone(withRequests.config)
	withoutConfig.actionRequestSchemas = nil
	local plainSuccess: boolean, _plainFailure: ServerTypes.StartupFailure?, plainBytes: number? = start(withoutConfig)
	expect(plainSuccess).toBe(true)
	assert(requestBytes ~= nil and plainBytes ~= nil, "Expected both bootstraps to be measured")

	-- Three ids, codes, targets and fixed Struct schemas; independent of the 50 Actions.
	expect(requestBytes > plainBytes).toBe(true)
	expect(requestBytes - plainBytes < 512).toBe(true)
end)

it("still rejects a genuinely oversized catalog before publication", function()
	local oversized: ServerTypes.ServerStartConfig = workload(50, false).config
	local commands: { NetworkingTypes.CommandDefinition } = {}

	-- Distinct large schemas cannot be shared by any dedup; this must exceed the bound.
	for index: number = 1, 192 do
		local command: NetworkingTypes.CommandDefinition =
			Commands.definition(string.format("Game.Huge%03d", index), "None")

		local fields: { [string]: SharedTypes.SchemaDefinition } = {}

		for field: number = 1, 16 do
			fields[string.format("field%02d_%03d_padding_for_bytes", field, index)] = Schema.U8
		end

		command.request = Schema.Struct(fields)
		table.insert(commands, command)
	end

	oversized.commands = commands
	local success: boolean, failure: ServerTypes.StartupFailure? = start(oversized)
	expect(success).toBe(false)
	expect(failure).toEqual({ system = "Networking", reason = "BootstrapManifestTooLarge" })
	expect(Server._IsInitialized()).toBe(false)
end)
