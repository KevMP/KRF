--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF

local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local ActionRequestTypes = require(KRF.shared.ActionRequest.types)
local SharedNetworkingTypes = require(KRF.shared.Networking.types)
local Schema: SharedNetworkingTypes.Schema = require(KRF.shared.Networking.Schema)
local Catalog: ActionRequestTypes.ActionRequestCatalogModule = require(KRF.shared.ActionRequest.ActionRequestCatalog)
local TestUtils = require(script.Parent.Parent.Utils.ActionRequestTestUtils)

it("compiles the shared request schemas into sorted Action ids with typed Start and Stop paths", function()
	local catalog: ActionRequestTypes.ActionRequestCatalog = TestUtils.compile(TestUtils.schemas())
	expect(catalog.actionIds).toEqual({ "Combat.Fireball", "Movement.Sprint", "Technique.Cast" })

	local fireball: ActionRequestTypes.CompiledActionRequest = TestUtils.request(catalog, "Combat.Fireball")
	expect(fireball.actionId).toBe("Combat.Fireball")
	expect(fireball.start.schema).never.toBeNil()
	expect(fireball.start.codec).never.toBeNil()
	expect(fireball.stop).toBeNil()
	expect(fireball.allowInputInterrupt).toBe(false)
	expect(fireball.requiresClientRelease).toBe(false)
	expect(fireball.onDisconnect).toBe("Keep")

	local sprint: ActionRequestTypes.CompiledActionRequest = TestUtils.request(catalog, "Movement.Sprint")
	expect(sprint.start.schema).toBeNil()
	expect(sprint.start.codec).toBeNil()
	assert(sprint.stop ~= nil, "An empty Stop table must declare a parameterless Stop path")
	expect(sprint.stop.schema).toBeNil()
	expect(sprint.allowInputInterrupt).toBe(true)
	expect(sprint.requiresClientRelease).toBe(true)
	expect(sprint.onDisconnect).toBe("Interrupt")

	local technique: ActionRequestTypes.CompiledActionRequest = TestUtils.request(catalog, "Technique.Cast")
	assert(technique.stop ~= nil, "Typed Stop parameters must declare a Stop path")
	expect(technique.stop.schema).never.toBeNil()
	expect(technique.stop.codec).never.toBeNil()
end)

it("compiles an empty schema module to an empty catalog that registers nothing", function()
	local catalog: ActionRequestTypes.ActionRequestCatalog = TestUtils.compile({})
	expect(catalog.actionIds).toEqual({})
	expect(next(catalog.requestsById)).toBeNil()
end)

it("owns frozen compiled contracts independently of later mutation of the shared module", function()
	local schemas: any = TestUtils.schemas()
	local catalog: ActionRequestTypes.ActionRequestCatalog = TestUtils.compile(schemas)
	local tag: number = TestUtils.request(catalog, "Combat.Fireball").contractTag

	schemas["Combat.Fireball"].start = Schema.U8
	schemas["Combat.Fireball"].allowInputInterrupt = true
	schemas["Game.Injected"] = { start = Schema.U8 }

	expect(table.isfrozen(catalog)).toBe(true)
	expect(table.isfrozen(catalog.actionIds)).toBe(true)
	expect(table.isfrozen(catalog.requestsById)).toBe(true)
	expect(table.isfrozen(TestUtils.request(catalog, "Combat.Fireball"))).toBe(true)
	expect(TestUtils.request(catalog, "Combat.Fireball").allowInputInterrupt).toBe(false)
	expect(TestUtils.request(catalog, "Combat.Fireball").contractTag).toBe(tag)
	expect(catalog.requestsById["Game.Injected"]).toBeNil()
end)

it("accepts an Action id at exactly the 96 byte wire bound", function()
	local actionId: string = string.rep("A", 96)
	local catalog: ActionRequestTypes.ActionRequestCatalog = TestUtils.compile({ [actionId] = {} })
	expect(catalog.actionIds).toEqual({ actionId })
end)

it("accepts Start and Stop payload schemas at exactly the 8192 byte inner bound", function()
	-- A String's encoded maximum includes its eight-byte conservative length prefix.
	local bounded: SharedNetworkingTypes.SchemaDefinition = Schema.String(8184)

	local catalog: ActionRequestTypes.ActionRequestCatalog = TestUtils.compile({
		["Game.Bounded"] = { start = bounded, stop = { parameters = bounded }, allowInputInterrupt = true },
	})

	expect(TestUtils.request(catalog, "Game.Bounded").start.schema).never.toBeNil()
end)

type InvalidCase = { label: string, schemas: any, reason: string }

local invalidCases: { InvalidCase } = {
	{ label = "a non-table module", schemas = true, reason = "ActionRequestSchemasMustBeTable" },
	{ label = "an array module", schemas = { { start = Schema.U8 } }, reason = "ActionRequestIdInvalid" },
	{ label = "an empty Action id", schemas = { [""] = {} }, reason = "ActionRequestIdInvalid" },
	{
		label = "an Action id over 96 bytes",
		schemas = { [string.rep("A", 97)] = {} },
		reason = "ActionRequestIdTooLong",
	},
	{ label = "an Action id with malformed UTF-8", schemas = { ["Bad\255"] = {} }, reason = "ActionRequestIdInvalid" },
	{ label = "a non-table entry", schemas = { ["Game.Bad"] = true }, reason = "ActionRequestSchemaMustBeTable" },
	{
		label = "an unknown entry field",
		schemas = { ["Game.Bad"] = { authorizeStart = function() end } },
		reason = "ActionRequestFieldUnknown",
	},
	{
		label = "client input policy inside the shared wire contract",
		schemas = { ["Game.Bad"] = { activation = "WhileDown" } },
		reason = "ActionRequestFieldUnknown",
	},
	{
		label = "an invalid Start schema",
		schemas = { ["Game.Bad"] = { start = { kind = "Unbounded" } } },
		reason = "ActionRequestStartSchemaInvalid",
	},
	{
		label = "a Start schema over 8192 encoded bytes",
		schemas = { ["Game.Bad"] = { start = Schema.String(8185) } },
		reason = "ActionRequestPayloadTooLarge",
	},
	{ label = "a non-table Stop", schemas = { ["Game.Bad"] = { stop = true } }, reason = "ActionRequestStopInvalid" },
	{
		label = "an unknown Stop field",
		schemas = { ["Game.Bad"] = { stop = { validateStop = function() end } } },
		reason = "ActionRequestStopInvalid",
	},
	{
		label = "an invalid Stop parameter schema",
		schemas = { ["Game.Bad"] = { stop = { parameters = { kind = "String" } } } },
		reason = "ActionRequestStopSchemaInvalid",
	},
	{
		label = "a Stop parameter schema over 8192 encoded bytes",
		schemas = { ["Game.Bad"] = { stop = { parameters = Schema.Array(Schema.U32, 4096) } } },
		reason = "ActionRequestPayloadTooLarge",
	},
	{
		label = "a non-boolean allowInputInterrupt",
		schemas = { ["Game.Bad"] = { allowInputInterrupt = "yes" } },
		reason = "ActionRequestFlagInvalid",
	},
	{
		label = "a non-boolean requiresClientRelease",
		schemas = { ["Game.Bad"] = { requiresClientRelease = 1 } },
		reason = "ActionRequestFlagInvalid",
	},
	{
		label = "an unknown disconnect policy",
		schemas = { ["Game.Bad"] = { onDisconnect = "End" } },
		reason = "ActionRequestDisconnectPolicyInvalid",
	},
	{
		label = "a release-dependent Action without a Stop path",
		schemas = { ["Game.Bad"] = { requiresClientRelease = true, onDisconnect = "Interrupt" } },
		reason = "ActionRequestReleaseRequiresStop",
	},
	{
		label = "a release-dependent Action that keeps running after disconnect",
		schemas = { ["Game.Bad"] = { stop = {}, requiresClientRelease = true, onDisconnect = "Keep" } },
		reason = "ActionRequestReleaseRequiresDisconnectInterrupt",
	},
	{
		label = "a release-dependent Action without a declared disconnect policy",
		schemas = { ["Game.Bad"] = { stop = {}, requiresClientRelease = true } },
		reason = "ActionRequestReleaseRequiresDisconnectInterrupt",
	},
}

for _, invalid: InvalidCase in invalidCases do
	it("rejects " .. invalid.label .. " with a stable reason", function()
		local catalog: ActionRequestTypes.ActionRequestCatalog?, reason: string? = Catalog.Compile(invalid.schemas)
		expect(catalog).toBeNil()
		expect(reason).toBe(invalid.reason)
	end)
end

it("rejects an invalid entry even when valid entries precede it in iteration", function()
	local schemas: any = TestUtils.schemas()
	schemas["Zz.Invalid"] = { onDisconnect = "Never" }
	local catalog: ActionRequestTypes.ActionRequestCatalog?, reason: string? = Catalog.Compile(schemas)
	expect(catalog).toBeNil()
	expect(reason).toBe("ActionRequestDisconnectPolicyInvalid")
end)
