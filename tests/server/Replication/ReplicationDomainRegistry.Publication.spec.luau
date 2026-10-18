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
local Validator: SharedNetworkingTypes.SchemaValidator = require(KRF.shared.Networking.utils.SchemaValidator)

local Registry: ReplicationTypes.InternalReplicationDomainRegistry =
	require(KRF.server.Replication.ReplicationDomainRegistry)

local TestUtils = require(script.Parent.Parent.Utils.Replication.ReplicationDomainTestUtils)

type ReplicationDomainDefinition = ReplicationTypes.ReplicationDomainDefinition
type LoadedDomain = ReplicationTypes.LoadedReplicationDomainDefinition
type PreparedCatalog = ReplicationTypes.PreparedReplicationDomainCatalog

beforeEach(function()
	Registry._resetForTests()
end)

afterEach(function()
	Registry._resetForTests()
end)

it("provides empty deterministic reads before publication and no runtime Register surface", function()
	expect(Registry.IsLoaded()).toBe(false)
	expect(Registry.Get("Game.Unknown")).toBeNil()
	expect(Registry.GetAll()).toEqual({})
	expect(Registry.GetAllById()).toEqual({})
	expect((Registry :: any).Register).toBeNil()
end)

it("publishes an empty catalog once and distinguishes loaded-empty from unloaded", function()
	TestUtils.load({})
	expect(Registry.IsLoaded()).toBe(true)
	expect(Registry.Get("Game.Unknown")).toBeNil()
	expect(Registry.GetAll()).toEqual({})
	expect(Registry.GetAllById()).toEqual({})
end)

it("publishes all domains with consistent hit, miss, array, and keyed reads", function()
	TestUtils.load({ TestUtils.createDomain("Game.First"), TestUtils.createDomain("Game.Second") })
	local first: LoadedDomain = Registry.Get("Game.First") :: LoadedDomain
	local second: LoadedDomain = Registry.Get("Game.Second") :: LoadedDomain
	expect(Registry.IsLoaded()).toBe(true)
	expect(first.id).toBe("Game.First")
	expect(second.id).toBe("Game.Second")
	expect(Registry.Get("Game.Unknown")).toBeNil()
	expect(Registry.GetAll()).toEqual(expect.arrayContaining({ first, second }))
	expect(#Registry.GetAll()).toBe(2)
	expect(Registry.GetAllById()).toEqual({ ["Game.First"] = first, ["Game.Second"] = second })
end)

it("rejects new preparation and repeated publication without replacing the published catalog", function()
	local first: PreparedCatalog = TestUtils.prepare({ TestUtils.createDomain("Game.First") })
	local second: PreparedCatalog = TestUtils.prepare({ TestUtils.createDomain("Game.Second") })
	local published: boolean, publishReason: string? = Registry.Publish(first)
	expect(published).toBe(true)
	expect(publishReason).toBeNil()
	local original: LoadedDomain = Registry.Get("Game.First") :: LoadedDomain

	local replacement: PreparedCatalog?, prepareReason: string? =
		Registry.Prepare({ TestUtils.createDomain("Game.Third") })

	expect(replacement).toBeNil()
	expect(prepareReason).toBe("ReplicationDomainDefinitionsAlreadyLoaded")
	local repeated: boolean, repeatedReason: string? = Registry.Publish(first)
	expect(repeated).toBe(false)
	expect(repeatedReason).toBe("ReplicationDomainDefinitionsAlreadyLoaded")
	local replaced: boolean, replaceReason: string? = Registry.Publish(second)
	expect(replaced).toBe(false)
	expect(replaceReason).toBe("ReplicationDomainDefinitionsAlreadyLoaded")
	expect(Registry.Get("Game.First")).toBe(original)
	expect(Registry.Get("Game.Second")).toBeNil()
	expect(Registry.Get("Game.Third")).toBeNil()
	expect(#Registry.GetAll()).toBe(1)
end)

it("owns prepared definitions before publication rather than retaining mutable caller tables", function()
	local definition: ReplicationDomainDefinition = TestUtils.createDomain("Game.Original")
	definition.events = { { id = "Changed", payload = Schema.U8 } }

	local sourceCatalog: { ReplicationDomainDefinition } = { definition }
	local prepared: PreparedCatalog = TestUtils.prepare(sourceCatalog)

	definition.id = "Game.Mutated"
	definition.audience = "Owner"
	(definition.events :: { ReplicationTypes.ReplicationEventDefinition })[1].id = "Mutated"
	table.clear(sourceCatalog)
	local published: boolean, reason: string? = Registry.Publish(prepared)
	expect(published).toBe(true)
	expect(reason).toBeNil()
	local loaded: LoadedDomain = Registry.Get("Game.Original") :: LoadedDomain
	expect(loaded.id).toBe("Game.Original")
	expect(loaded.audience).toBe("All")
	expect(loaded.events[1].id).toBe("Changed")
	expect(Registry.Get("Game.Mutated")).toBeNil()
end)

it("source catalog, callbacks, events, and nested schemas cannot alter published contracts", function()
	local sourceValues: { string } = { "Idle", "Blocking" }
	local sourceState: any = { kind = "Struct", fields = { mode = { kind = "Enum", values = sourceValues } } }
	local sourcePayload: any = { kind = "Struct", fields = { amount = { kind = "U8" } } }

	local definition: ReplicationDomainDefinition = TestUtils.createDomain("Game.Original")
	definition.state = sourceState
	definition.events = { { id = "Changed", payload = sourcePayload } }

	definition.observe = function(
		_actor: ActorTypes.Actor,
		_onCommitted: ReplicationTypes.ReplicationDomainOnCommitted
	): (() -> ())?
		return function() end
	end

	local originalSnapshot: (ActorTypes.Actor) -> any = definition.snapshot

	local originalObserve: ((ActorTypes.Actor, ReplicationTypes.ReplicationDomainOnCommitted) -> (() -> ())?)? =
		definition.observe

	local sourceCatalog: { ReplicationDomainDefinition } = { definition }
	TestUtils.load(sourceCatalog)
	definition.id = "Game.Mutated"
	definition.audience = "Owner"

	definition.snapshot = function(_actor: ActorTypes.Actor): any
		return { mutated = true }
	end

	definition.observe = nil
	(definition.events :: { ReplicationTypes.ReplicationEventDefinition })[1].id = "Mutated"
	(definition.events :: { ReplicationTypes.ReplicationEventDefinition })[1].payload = Schema.Boolean

	table.insert(
		definition.events :: { ReplicationTypes.ReplicationEventDefinition },
		{ id = "Injected", payload = Schema.F64 }
	)

	sourceValues[1] = "Flying"
	sourceState.fields.mode.kind = "Boolean"
	sourcePayload.fields.amount.kind = "Boolean"
	table.clear(sourceCatalog)
	local loaded: LoadedDomain = Registry.Get("Game.Original") :: LoadedDomain
	expect(loaded.id).toBe("Game.Original")
	expect(loaded.audience).toBe("All")
	expect(loaded.snapshot).toBe(originalSnapshot)
	expect(loaded.observe).toBe(originalObserve)
	expect(#loaded.events).toBe(1)
	expect(loaded.events[1].id).toBe("Changed")
	local stateValid: boolean, stateReason: string? = Validator.Validate(loaded.state, { mode = "Idle" })
	local eventValid: boolean, eventReason: string? = Validator.Validate(loaded.events[1].payload, { amount = 255 })
	expect(stateValid).toBe(true)
	expect(stateReason).toBeNil()
	expect(eventValid).toBe(true)
	expect(eventReason).toBeNil()
	expect(Registry.Get("Game.Mutated")).toBeNil()
	expect(#Registry.GetAll()).toBe(1)
	expect(table.isfrozen(definition)).toBe(false)
	expect(table.isfrozen(sourceState)).toBe(false)
	expect(table.isfrozen(sourceCatalog)).toBe(false)
end)

it("published domain, event, and compiled schema metadata are recursively immutable", function()
	local definition: ReplicationDomainDefinition = TestUtils.createDomain("Game.State")
	definition.events = { { id = "Changed", payload = Schema.Enum({ "Idle", "Blocking" }) } }
	TestUtils.load({ definition })
	local loaded: LoadedDomain = Registry.Get(definition.id) :: LoadedDomain
	local stateSchema: SharedNetworkingTypes.CompiledSchema = loaded.state
	local eventSchema: SharedNetworkingTypes.CompiledSchema = loaded.events[1].payload

	local domainMutable: boolean = pcall(function()
		(loaded :: any).audience = "Owner"
	end)

	local eventsMutable: boolean = pcall(function()
		table.clear(loaded.events)
	end)

	local eventMutable: boolean = pcall(function()
		(loaded.events[1] :: any).id = "Mutated"
	end)

	local schemaMutable: boolean = pcall(function()
		loaded.state.maxEncodedBytes = math.huge
	end)

	assert(stateSchema.kind == "Struct", "Expected a compiled state Struct")
	assert(eventSchema.kind == "Enum", "Expected a compiled event Enum")
	expect(domainMutable).toBe(false)
	expect(eventsMutable).toBe(false)
	expect(eventMutable).toBe(false)
	expect(schemaMutable).toBe(false)
	expect(table.isfrozen(stateSchema.fields)).toBe(true)
	expect(table.isfrozen(stateSchema.fields[1])).toBe(true)
	expect(table.isfrozen(stateSchema.fields[1].schema)).toBe(true)
	expect(table.isfrozen(eventSchema.values)).toBe(true)
end)

it("mutating registry read collections cannot remove, replace, or insert registry-owned entries", function()
	TestUtils.load({ TestUtils.createDomain("Game.First"), TestUtils.createDomain("Game.Second") })
	local first: LoadedDomain = Registry.Get("Game.First") :: LoadedDomain
	local second: LoadedDomain = Registry.Get("Game.Second") :: LoadedDomain
	local all: { LoadedDomain } = Registry.GetAll()
	local byId: { [string]: LoadedDomain } = Registry.GetAllById()

	-- Both frozen collections and defensive copies satisfy read ownership.
	pcall(function()
		table.clear(all)
	end)

	pcall(function()
		byId["Game.First"] = second
	end)

	pcall(function()
		byId["Game.Second"] = nil
	end)

	pcall(function()
		byId["Game.Injected"] = first
	end)

	expect(Registry.Get("Game.First")).toBe(first)
	expect(Registry.Get("Game.Second")).toBe(second)
	expect(Registry.Get("Game.Injected")).toBeNil()
	expect(#Registry.GetAll()).toBe(2)
	expect(Registry.GetAllById()).toEqual({ ["Game.First"] = first, ["Game.Second"] = second })
end)

it("test reset clears publication and repeated resets leave no stale domain state", function()
	TestUtils.load({ TestUtils.createDomain("Game.Old") })
	Registry._resetForTests()
	Registry._resetForTests()
	expect(Registry.IsLoaded()).toBe(false)
	expect(Registry.Get("Game.Old")).toBeNil()
	expect(Registry.GetAll()).toEqual({})
	expect(Registry.GetAllById()).toEqual({})
	TestUtils.load({ TestUtils.createDomain("Game.New") })
	expect(Registry.IsLoaded()).toBe(true)
	expect(Registry.Get("Game.Old")).toBeNil()
	expect((Registry.Get("Game.New") :: LoadedDomain).id).toBe("Game.New")
end)
