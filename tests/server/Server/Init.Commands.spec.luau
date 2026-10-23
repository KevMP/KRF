--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local ServerTypes = require(KRF.server.types)
local SharedTypes = require(KRF.shared.Networking.types)
local NetworkingTypes = require(KRF.server.Networking.types)
local Server = require(KRF.server)
local Networking: NetworkingTypes.ServerNetworking = require(KRF.server.Networking.ServerNetworking)
local Controllers = require(KRF.server.Controller.ControllerRegistry)
local Tags = require(KRF.server.Tags.TagRegistry)
local Resources = require(KRF.server.Resource.ResourceRegistry)
local Actions = require(KRF.server.Action.ActionRegistry)
local Domains = require(KRF.server.Replication.ReplicationDomainRegistry)
local Transport = require(KRF.shared.Networking.Transport)
local Schema: SharedTypes.Schema = require(KRF.shared.Networking.Schema)
local SchemaCompiler = require(KRF.shared.Networking.utils.SchemaCompiler)
local Commands = require(script.Parent.Parent.Parent.shared.Utils.Networking.CommandTestUtils)
local Registry = require(KRF.server.Networking.CommandRegistry)

local originalPublish: typeof(Networking.Publish) = Networking.Publish

beforeEach(function()
	Server._ResetForTests()
end)

afterEach(function()
	Networking.Publish = originalPublish
	Server._ResetForTests()
end)

it(
	"preserves the published catalog when preparation or publication is repeated outside the startup transaction",
	function()
		local catalog: NetworkingTypes.PreparedCommandCatalog?, reason: string? = Registry.Prepare({})
		assert(catalog ~= nil, reason)
		expect((Registry.Publish(catalog))).toBe(true)
		local repeated: NetworkingTypes.PreparedCommandCatalog? = nil
		repeated, reason = Registry.Prepare({})
		expect(repeated).toBeNil()
		expect(reason).toBe("CommandDefinitionsAlreadyLoaded")
		local published: boolean = false
		published, reason = Registry.Publish(catalog)
		expect(published).toBe(false)
		expect(reason).toBe("CommandDefinitionsAlreadyLoaded")
		expect(Registry.GetAll()).toBe(catalog.orderedDefinitions)
		local started: boolean, failure: ServerTypes.StartupFailure? = Server.Init({})
		expect(started).toBe(false)
		expect(failure).toEqual({ system = "Server", reason = "CatalogAlreadyLoaded" })
	end
)

it("rejects non-string command definition fields without publishing any catalog", function()
	local invalid: any = Commands.definition("Game.Invalid")
	invalid[1] = true
	local catalog: NetworkingTypes.PreparedCommandCatalog?, reason: string? = Registry.Prepare({ invalid })
	expect(catalog).toBeNil()
	expect(reason).toBe("CommandFieldUnknown")
	expect(Registry.IsLoaded()).toBe(false)
end)

local function expectUnpublished(): ()
	expect(Server._IsInitialized()).toBe(false)
	expect(Networking._IsInitialized()).toBe(false)
	expect(Controllers.IsLoaded()).toBe(false)
	expect(Tags.IsLoaded()).toBe(false)
	expect(Resources.IsLoaded()).toBe(false)
	expect(Actions.IsLoaded()).toBe(false)
	expect(Domains.IsLoaded()).toBe(false)
	expect(ReplicatedStorage:FindFirstChild(Transport.ROOT_NAME)).toBeNil()
end

local function expectRejected(definitions: any): string
	local success: boolean, failure: ServerTypes.StartupFailure? = Server.Init({ commands = definitions } :: any)
	expect(success).toBe(false)
	assert(failure ~= nil, "Invalid command catalog must produce an observable startup failure")
	expect(type(failure.reason)).toBe("string")
	expect(#failure.reason > 0).toBe(true)
	expectUnpublished()

	return failure.reason
end

it("starts an explicitly empty command catalog without registering Action commands", function()
	local success: boolean, failure: ServerTypes.StartupFailure? = Server.Init({ commands = {} } :: any)
	expect(success).toBe(true)
	expect(failure).toBeNil()
	local registry: Commands.Registry = Commands.registry()
	expect(registry.IsLoaded()).toBe(true)
	expect(registry.GetAll()).toEqual({})
	expect(registry.Get("KRF.Action.Start")).toBeNil()
	expect(registry.Get("KRF.Action.Stop")).toBeNil()
end)

it("publishes valid None and Actor commands without executing author code at startup", function()
	local calls: number = 0
	local first: Commands.Definition = Commands.definition("Game.Ping")
	local second: Commands.Definition = Commands.definition("Game.Interact", "Actor")

	first.authorize = function(): (boolean, string?)
		calls += 1
		error("StartupMustNotAuthorize")
	end

	second.handle = function(): any
		calls += 1
		error("StartupMustNotHandle")
	end

	local success: boolean, failure: ServerTypes.StartupFailure? = Server.Init({ commands = { first, second } } :: any)
	expect(success).toBe(true)
	expect(failure).toBeNil()
	expect(calls).toBe(0)
	local registry: Commands.Registry = Commands.registry()
	expect(#registry.GetAll()).toBe(2)
	expect(registry.Get(first.id).target).toBe("None")
	expect(registry.Get(second.id).target).toBe("Actor")
	expect(registry.Get(first.id).authorize).toBe(first.authorize)
	expect(registry.Get(second.id).handle).toBe(second.handle)
end)

it("rejects duplicate command ids deterministically and leaves all registries unpublished", function()
	local first: Commands.Definition = Commands.definition("Game.Duplicate")
	local second: Commands.Definition = Commands.definition("Game.Duplicate", "Actor")
	local reason: string = expectRejected({ first, second })
	Server._ResetForTests()
	expect(expectRejected({ second, first })).toBe(reason)
end)

for _, invalid: any in
	{
		{ label = "non-table catalog", catalog = true },
		{ label = "dictionary catalog", catalog = { Ping = Commands.definition("Game.Ping") } },
		{ label = "sparse catalog", catalog = { [2] = Commands.definition("Game.Ping") } },
		{ label = "non-table definition", catalog = { false } },
	}
do
	it("rejects " .. invalid.label .. " transactionally", function()
		expectRejected(invalid.catalog)
	end)
end

for _, invalid: any in
	{
		{ label = "missing id", field = "id" },
		{ label = "empty id", field = "id", value = "" },
		{ label = "non-string id", field = "id", value = 12 },
		{ label = "missing target", field = "target" },
		{ label = "unknown target", field = "target", value = "Player" },
		{ label = "lowercase target", field = "target", value = "actor" },
		{ label = "missing authorization", field = "authorize" },
		{ label = "non-function authorization", field = "authorize", value = true },
		{ label = "missing handler", field = "handle" },
		{ label = "non-function handler", field = "handle", value = {} },
	}
do
	it("rejects " .. invalid.label .. " even after a valid command was staged", function()
		local definition: any = Commands.definition("Game.Invalid")
		definition[invalid.field] = invalid.value
		expectRejected({ Commands.definition("Game.Valid"), definition })
	end)
end

for _, field: string in { "request", "result" } do
	for _, schema: any in { { kind = "Unbounded" }, { kind = "String" }, { kind = "Array", maxLength = -1 } } do
		it("rejects invalid " .. field .. " schema " .. schema.kind .. " before publication", function()
			local definition: any = Commands.definition("Game.InvalidSchema")
			definition[field] = schema
			expectRejected({ definition })
		end)
	end

	it("rejects a finite but impractically large maximum " .. field .. " before startup allocation", function()
		local schema: SharedTypes.SchemaDefinition = Schema.Array(Schema.U8, 1073741824)
		local compiled: SharedTypes.CompiledSchema?, reason: string? = SchemaCompiler.Compile(schema)
		expect(reason).toBeNil()
		assert(compiled ~= nil, "Fixture must be a valid finite N1 schema")
		expect(compiled.maxEncodedBytes < math.huge).toBe(true)

		local definition: any = Commands.definition("Game.Oversized")
		definition[field] = schema
		expectRejected({ definition })
	end)
end

it("owns frozen loaded definitions and nested schemas independently of author tables", function()
	local fields: { [string]: SharedTypes.SchemaDefinition } = { count = Schema.U16 }

	local definition: Commands.Definition = Commands.definition("Game.Immutable")
	definition.request = { kind = "Struct", fields = fields }
	definition.result = Schema.Struct({ sequenceId = Schema.U32 })

	local originalHandler: typeof(definition.handle) = definition.handle
	local success: boolean = Server.Init({ commands = { definition } } :: any)
	expect(success).toBe(true)
	local registry: Commands.Registry = Commands.registry()
	local loaded: any = registry.Get("Game.Immutable")
	assert(loaded ~= nil, "Successful startup must retain the command definition")
	definition.id = "Game.Mutated"
	definition.target = "Actor"
	fields.count = Schema.String(100)

	definition.handle = function(): any
		error("MutatedHandler")
	end

	expect(loaded.id).toBe("Game.Immutable")
	expect(loaded.target).toBe("None")
	expect(loaded.handle).toBe(originalHandler)
	expect(table.isfrozen(loaded)).toBe(true)
	expect(table.isfrozen(loaded.request)).toBe(true)
	expect(table.isfrozen(loaded.result)).toBe(true)
	expect(loaded.request.maxEncodedBytes).toBe(2)
	expect(loaded.result.maxEncodedBytes).toBe(4)
	expect(table.isfrozen(registry.GetAll())).toBe(true)
	expect(registry.Get("Game.Mutated")).toBeNil()
end)

it("rolls back the command catalog with all N1-N8 registries when transport activation fails", function()
	local registry: Commands.Registry = Commands.registry()

	Networking.Publish = function(_protocol: SharedTypes.PreparedProtocol): (boolean, string?)
		expect(registry.IsLoaded()).toBe(true)
		expect(registry.Get("Game.Rollback").id).toBe("Game.Rollback")

		return false, "TransportConflict"
	end

	local success: boolean, failure: ServerTypes.StartupFailure? =
		Server.Init({ commands = { Commands.definition("Game.Rollback") } } :: any)

	expect(success).toBe(false)
	expect(failure).toEqual({ system = "Networking", reason = "TransportConflict" })
	expectUnpublished()
	expect(registry.IsLoaded()).toBe(false)
	expect(registry.GetAll()).toEqual({})
	expect(registry.Get("Game.Rollback")).toBeNil()
end)
