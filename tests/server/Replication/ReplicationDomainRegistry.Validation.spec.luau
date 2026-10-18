--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF

local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local ActorTypes = require(KRF.server.Actor.types)
local ReplicationTypes = require(KRF.server.Replication.types)
local SharedNetworkingTypes = require(KRF.shared.Networking.types)
local Schema: SharedNetworkingTypes.Schema = require(KRF.shared.Networking.Schema)
local Registry: ReplicationTypes.InternalReplicationDomainRegistry =
	require(KRF.server.Replication.ReplicationDomainRegistry)
local TestUtils = require(script.Parent.Parent.Utils.Replication.ReplicationDomainTestUtils)

type Actor = ActorTypes.Actor
type ReplicationDomainDefinition = ReplicationTypes.ReplicationDomainDefinition
type PreparedCatalog = ReplicationTypes.PreparedReplicationDomainCatalog

beforeEach(function()
	Registry._resetForTests()
end)

afterEach(function()
	Registry._resetForTests()
end)

local function expectRejected(definitions: any, expectedReason: string): ()
	local prepared: PreparedCatalog?, reason: string? = Registry.Prepare(definitions)
	expect(prepared).toBeNil()
	expect(reason).toBe(expectedReason)
	expect(Registry.IsLoaded()).toBe(false)
	expect(Registry.GetAll()).toEqual({})
	expect(Registry.GetAllById()).toEqual({})
end

it("prepares a minimal domain with default All audience and empty events without publishing", function()
	local definition: ReplicationDomainDefinition = TestUtils.createDomain("Game.CombatState")
	local prepared: PreparedCatalog = TestUtils.prepare({ definition })
	local loaded: ReplicationTypes.LoadedReplicationDomainDefinition = prepared.definitionsById[definition.id]
	expect(loaded.id).toBe("Game.CombatState")
	expect(loaded.audience).toBe("All")
	expect(loaded.events).toEqual({})
	expect(loaded.observe).toBeNil()
	expect(loaded.state.kind).toBe("Struct")
	expect(loaded.snapshot).toBe(definition.snapshot)
	expect(Registry.IsLoaded()).toBe(false)
	expect(Registry.Get(definition.id)).toBeNil()
end)

it("prepares empty and multiple-domain catalogs as complete unpublished candidates", function()
	local empty: PreparedCatalog = TestUtils.prepare({})
	expect(empty.orderedDefinitions).toEqual({})
	expect(empty.definitionsById).toEqual({})
	local multiple: PreparedCatalog = TestUtils.prepare({
		TestUtils.createDomain("Game.CombatState"),
		TestUtils.createDomain("Game.Targeting"),
	})
	expect(#multiple.orderedDefinitions).toBe(2)
	expect(multiple.definitionsById["Game.CombatState"].id).toBe("Game.CombatState")
	expect(multiple.definitionsById["Game.Targeting"].id).toBe("Game.Targeting")
	expect(Registry.GetAll()).toEqual({})
end)

it("accepts explicit All and Owner audiences", function()
	local public: ReplicationDomainDefinition = TestUtils.createDomain("Game.Public")
	local private: ReplicationDomainDefinition = TestUtils.createDomain("Game.Private")
	public.audience = "All"
	private.audience = "Owner"
	local prepared: PreparedCatalog = TestUtils.prepare({ public, private })
	expect(prepared.definitionsById[public.id].audience).toBe("All")
	expect(prepared.definitionsById[private.id].audience).toBe("Owner")
end)

it("preserves optional observation and snapshot callbacks without invoking them during startup", function()
	local snapshotCalls: number = 0
	local observeCalls: number = 0
	local definition: ReplicationDomainDefinition = TestUtils.createDomain("Game.Observed")
	definition.snapshot = function(_actor: Actor): any
		snapshotCalls += 1
		error("SnapshotMustNotRunDuringStartup")
	end
	definition.observe = function(
		_actor: Actor,
		_onCommitted: ReplicationTypes.ReplicationDomainOnCommitted
	): (() -> ())?
		observeCalls += 1
		error("ObserveMustNotRunDuringStartup")
	end
	TestUtils.load({ definition })
	local loaded: ReplicationTypes.LoadedReplicationDomainDefinition =
		Registry.Get(definition.id) :: ReplicationTypes.LoadedReplicationDomainDefinition
	expect(loaded.snapshot).toBe(definition.snapshot)
	expect(loaded.observe).toBe(definition.observe)
	expect(snapshotCalls).toBe(0)
	expect(observeCalls).toBe(0)
end)

type InvalidDomainCase = { name: string, field: string, value: any, reason: string }
local invalidDomains: { InvalidDomainCase } = {
	{ name = "missing id", field = "id", value = nil, reason = "ReplicationDomainIdMissing" },
	{ name = "numeric id", field = "id", value = 1, reason = "ReplicationDomainIdMustBeString" },
	{ name = "empty id", field = "id", value = "", reason = "ReplicationDomainIdCannotBeEmpty" },
	{ name = "missing state", field = "state", value = nil, reason = "ReplicationDomainStateMissing" },
	{ name = "non-table state", field = "state", value = "U8", reason = "SchemaDefinitionMustBeTable" },
	{ name = "unknown state schema", field = "state", value = {}, reason = "SchemaKindInvalid" },
	{ name = "missing snapshot", field = "snapshot", value = nil, reason = "ReplicationDomainSnapshotMustBeFunction" },
	{
		name = "non-function snapshot",
		field = "snapshot",
		value = {},
		reason = "ReplicationDomainSnapshotMustBeFunction",
	},
	{
		name = "non-function observe",
		field = "observe",
		value = false,
		reason = "ReplicationDomainObserveMustBeFunction",
	},
	{ name = "unknown audience", field = "audience", value = "Everyone", reason = "ReplicationDomainAudienceInvalid" },
	{ name = "non-string audience", field = "audience", value = true, reason = "ReplicationDomainAudienceInvalid" },
	{ name = "empty audience", field = "audience", value = "", reason = "ReplicationDomainAudienceInvalid" },
}
for _, domainCase: InvalidDomainCase in invalidDomains do
	it("rejects a domain with " .. domainCase.name .. " without publishing an earlier valid domain", function()
		local invalid: any = TestUtils.createDomain("Game.Invalid")
		invalid[domainCase.field] = domainCase.value
		expectRejected({ TestUtils.createDomain("Game.Valid"), invalid }, domainCase.reason)
		expect(Registry.Get("Game.Valid")).toBeNil()
	end)
end

it("rejects non-table catalogs and non-dense catalog entries", function()
	expectRejected(nil, "ReplicationDomainDefinitionsMustBeTable")
	expectRejected("Game.CombatState", "ReplicationDomainDefinitionsMustBeTable")
	expectRejected({ [2] = TestUtils.createDomain("Game.CombatState") }, "ReplicationDomainDefinitionsMustBeArray")
	expectRejected({ named = TestUtils.createDomain("Game.CombatState") }, "ReplicationDomainDefinitionsMustBeArray")
	expectRejected({ 1 }, "ReplicationDomainDefinitionMustBeTable")
end)

it("rejects duplicate domain ids deterministically across the shared framework and game namespace", function()
	expectRejected({ TestUtils.createDomain("Tags"), TestUtils.createDomain("Tags") }, "DuplicateReplicationDomainId")
	expectRejected(
		{ TestUtils.createDomain("Game.State"), TestUtils.createDomain("Game.State") },
		"DuplicateReplicationDomainId"
	)
end)

it("recursively rejects invalid state schemas before publishing any domain", function()
	local definition: any = TestUtils.createDomain("Game.Invalid")
	definition.state = { kind = "Struct", fields = { nested = { kind = "String" } } }
	expectRejected({ TestUtils.createDomain("Game.Valid"), definition }, "SchemaStringMaxBytesInvalid")
end)

it("accepts bounded event schemas and permits the same event id in different domains", function()
	local first: ReplicationDomainDefinition = TestUtils.createDomain("Game.First")
	local second: ReplicationDomainDefinition = TestUtils.createDomain("Game.Second")
	first.events = { { id = "Changed", payload = Schema.Struct({ amount = Schema.F32 }) } }
	second.events = { { id = "Changed", payload = Schema.U8 } }
	local prepared: PreparedCatalog = TestUtils.prepare({ first, second })
	expect(prepared.definitionsById[first.id].events[1].id).toBe("Changed")
	expect(prepared.definitionsById[first.id].events[1].payload.kind).toBe("Struct")
	expect(prepared.definitionsById[second.id].events[1].id).toBe("Changed")
	expect(prepared.definitionsById[second.id].events[1].payload.kind).toBe("U8")
end)

type InvalidEventCase = { name: string, events: any, reason: string }
local invalidEvents: { InvalidEventCase } = {
	{ name = "non-table collection", events = false, reason = "ReplicationEventsMustBeArray" },
	{ name = "dictionary collection", events = { Changed = {} }, reason = "ReplicationEventsMustBeArray" },
	{
		name = "sparse collection",
		events = { [2] = { id = "Changed", payload = Schema.U8 } },
		reason = "ReplicationEventsMustBeArray",
	},
	{ name = "non-table definition", events = { false }, reason = "ReplicationEventDefinitionMustBeTable" },
	{ name = "missing id", events = { { payload = Schema.U8 } }, reason = "ReplicationEventIdMissing" },
	{ name = "non-string id", events = { { id = 1, payload = Schema.U8 } }, reason = "ReplicationEventIdMustBeString" },
	{ name = "empty id", events = { { id = "", payload = Schema.U8 } }, reason = "ReplicationEventIdCannotBeEmpty" },
	{ name = "missing payload", events = { { id = "Changed" } }, reason = "ReplicationEventPayloadMissing" },
	{ name = "invalid payload", events = { { id = "Changed", payload = {} } }, reason = "SchemaKindInvalid" },
	{
		name = "unbounded nested payload",
		events = { { id = "Changed", payload = { kind = "Array", element = Schema.U8 } } },
		reason = "SchemaArrayMaxLengthInvalid",
	},
}
for _, eventCase: InvalidEventCase in invalidEvents do
	it("rejects event declarations with " .. eventCase.name .. " transactionally", function()
		local invalid: any = TestUtils.createDomain("Game.Invalid")
		invalid.events = eventCase.events
		expectRejected({ TestUtils.createDomain("Game.Valid"), invalid }, eventCase.reason)
	end)
end

it("rejects duplicate event ids within a domain", function()
	local definition: ReplicationDomainDefinition = TestUtils.createDomain("Game.CombatState")
	definition.events = { { id = "Changed", payload = Schema.U8 }, { id = "Changed", payload = Schema.F32 } }
	expectRejected({ definition }, "DuplicateReplicationEventId")
end)

it("failed preparation leaves consumer definitions mutable and permits corrected preparation", function()
	local definition: any = TestUtils.createDomain("Game.Corrected")
	definition.audience = "Everyone"
	expectRejected({ definition }, "ReplicationDomainAudienceInvalid")
	expect(table.isfrozen(definition)).toBe(false)
	definition.audience = "Owner"
	local prepared: PreparedCatalog = TestUtils.prepare({ definition })
	expect(prepared.definitionsById[definition.id].audience).toBe("Owner")
	expect(Registry.IsLoaded()).toBe(false)
end)

it("rejects packet metadata and undeclared fields in semantic domain definitions", function()
	local unsupportedFields: { any } = { "wireId", "packetOpcode", "remote", "revision", "flushInterval", 1 }
	for _, field: any in unsupportedFields do
		local definition: any = TestUtils.createDomain("Game.Invalid")
		definition[field] = true
		expectRejected({ TestUtils.createDomain("Game.Valid"), definition }, "ReplicationDomainFieldUnknown")
	end
end)

it("rejects event wire metadata before publishing the containing domain", function()
	local definition: any = TestUtils.createDomain("Game.Invalid")
	definition.events = { { id = "Changed", payload = Schema.U8, wireId = 1 } }
	expectRejected({ TestUtils.createDomain("Game.Valid"), definition }, "ReplicationEventFieldUnknown")
end)
