--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF

local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local ServerTypes = require(KRF.server.types)
local ActorTypes = require(KRF.server.Actor.types)
local ControllerTypes = require(KRF.server.Controller.types)
local TagTypes = require(KRF.server.Tags.types)
local ResourceTypes = require(KRF.server.Resource.types)
local ActionTypes = require(KRF.server.Action.types)
local ReplicationTypes = require(KRF.server.Replication.types)
local NetworkingTypes = require(KRF.shared.Networking.types)
local Server = require(KRF.server)
local Schema: NetworkingTypes.Schema = require(KRF.shared.Networking.Schema)
local Controllers: ControllerTypes.ControllerRegistry = require(KRF.server.Controller.ControllerRegistry)
local Tags: TagTypes.TagRegistry = require(KRF.server.Tags.TagRegistry)
local Resources: ResourceTypes.ResourceRegistry = require(KRF.server.Resource.ResourceRegistry)
local Actions: ActionTypes.ActionRegistry = require(KRF.server.Action.ActionRegistry)
local Domains: ReplicationTypes.InternalReplicationDomainRegistry =
	require(KRF.server.Replication.ReplicationDomainRegistry)
local TestUtils = require(script.Parent.Parent.Utils.Replication.ReplicationDomainTestUtils)

type ServerStartConfig = ServerTypes.ServerStartConfig
type StartupFailure = ServerTypes.StartupFailure
type ReplicationDomainDefinition = ReplicationTypes.ReplicationDomainDefinition
type LoadedDomain = ReplicationTypes.LoadedReplicationDomainDefinition

beforeEach(function()
	Server._ResetForTests()
end)

afterEach(function()
	Server._ResetForTests()
end)

local function expectFailure(failure: StartupFailure?, system: string, reason: string): ()
	expect(failure).toEqual({ system = system, reason = reason })
end

local function expectUnpublished(): ()
	expect(Server._IsInitialized()).toBe(false)
	expect(Controllers.IsLoaded()).toBe(false)
	expect(Tags.IsLoaded()).toBe(false)
	expect(Resources.IsLoaded()).toBe(false)
	expect(Actions.IsLoaded()).toBe(false)
	expect(Domains.IsLoaded()).toBe(false)
	expect(Controllers.GetKeys()).toEqual({})
	expect(Tags.GetAll()).toEqual({})
	expect(Resources.GetAll()).toEqual({})
	expect(Actions.GetAll()).toEqual({})
	expect(Domains.GetAll()).toEqual({})
	expect(Domains.GetAllById()).toEqual({})
end

it("omitting game replication domains publishes an empty N1 domain catalog", function()
	local started: boolean, failure: StartupFailure? = Server.Init({})
	expect(started).toBe(true)
	expect(failure).toBeNil()
	expect(Server._IsInitialized()).toBe(true)
	expect(Domains.IsLoaded()).toBe(true)
	expect(Domains.GetAll()).toEqual({})
end)

it("an explicit empty game replication catalog succeeds", function()
	local config: ServerStartConfig = { replicationDomains = {} }
	local started: boolean, failure: StartupFailure? = Server.Init(config)
	expect(started).toBe(true)
	expect(failure).toBeNil()
	expect(Domains.IsLoaded()).toBe(true)
	expect(Domains.GetAllById()).toEqual({})
end)

it("publishes replication domains together with controllers, tags, resources, and actions", function()
	local definition: ReplicationDomainDefinition = TestUtils.createDomain("Game.CombatState")
	definition.events = { { id = "GuardBroken", payload = Schema.Struct({ previousGuard = Schema.F32 }) } }
	local config: ServerStartConfig = {
		controllers = {
			{
				key = "Game.CombatController",
				factory = function(_actor: ActorTypes.Actor): ActorTypes.Controller
					return { Destroy = function() end }
				end,
			},
		},
		tags = { { id = "Game.Grounded", duplicateBehavior = "Ignore", visibility = "ServerOnly" } },
		resources = { { id = "Game.Guard", max = { value = 100 }, visibility = "ServerOnly" } },
		actions = {
			function(): ActionTypes.ActionDefinition
				return {
					id = "Game.Block",
					visibility = "ServerOnly",
					requiredTags = { "Game.Grounded" },
					costs = { ["Game.Guard"] = 1 },
				}
			end,
		},
		replicationDomains = { definition, TestUtils.createDomain("Game.Targeting") },
	}
	local started: boolean, failure: StartupFailure? = Server.Init(config)
	expect(started).toBe(true)
	expect(failure).toBeNil()
	expect(Controllers.IsLoaded()).toBe(true)
	expect(Tags.IsLoaded()).toBe(true)
	expect(Resources.IsLoaded()).toBe(true)
	expect(Actions.IsLoaded()).toBe(true)
	expect(Domains.IsLoaded()).toBe(true)
	local loaded: LoadedDomain = Domains.Get(definition.id) :: LoadedDomain
	expect(loaded.id).toBe("Game.CombatState")
	expect(loaded.state.kind).toBe("Struct")
	expect(loaded.events[1].id).toBe("GuardBroken")
	expect(loaded.events[1].payload.kind).toBe("Struct")
	expect(loaded.snapshot).toBe(definition.snapshot)
	expect((Domains.Get("Game.Targeting") :: LoadedDomain).id).toBe("Game.Targeting")
end)

it("keeps domain ids independent from controller keys and allows projections with no matching controller", function()
	local started: boolean, failure: StartupFailure? = Server.Init({
		controllers = {
			{
				key = "Game.SharedName",
				factory = function(_actor: ActorTypes.Actor): ActorTypes.Controller
					return { Destroy = function() end }
				end,
			},
		},
		replicationDomains = { TestUtils.createDomain("Game.SharedName"), TestUtils.createDomain("Game.Projection") },
	})
	expect(started).toBe(true)
	expect(failure).toBeNil()
	expect((Domains.Get("Game.SharedName") :: LoadedDomain).id).toBe("Game.SharedName")
	expect((Domains.Get("Game.Projection") :: LoadedDomain).id).toBe("Game.Projection")
	expect(Controllers.Get("Game.Projection")).toBeNil()
end)

type InvalidStartupCase = { name: string, field: string, value: any, reason: string }
local invalidDomains: { InvalidStartupCase } = {
	{ name = "id", field = "id", value = "", reason = "ReplicationDomainIdCannotBeEmpty" },
	{ name = "state schema", field = "state", value = {}, reason = "SchemaKindInvalid" },
	{ name = "snapshot", field = "snapshot", value = false, reason = "ReplicationDomainSnapshotMustBeFunction" },
	{ name = "observe adapter", field = "observe", value = true, reason = "ReplicationDomainObserveMustBeFunction" },
	{ name = "audience", field = "audience", value = "Everyone", reason = "ReplicationDomainAudienceInvalid" },
	{
		name = "event payload",
		field = "events",
		value = { { id = "Changed", payload = {} } },
		reason = "SchemaKindInvalid",
	},
	{
		name = "duplicate event ids",
		field = "events",
		value = { { id = "Changed", payload = Schema.U8 }, { id = "Changed", payload = Schema.U8 } },
		reason = "DuplicateReplicationEventId",
	},
}
for _, domainCase: InvalidStartupCase in invalidDomains do
	it("an invalid domain " .. domainCase.name .. " leaves every startup catalog unpublished", function()
		local invalid: any = TestUtils.createDomain("Game.Invalid")
		invalid[domainCase.field] = domainCase.value
		local started: boolean, failure: StartupFailure? = Server.Init({
			tags = { { id = "Game.ValidTag", duplicateBehavior = "Ignore", visibility = "ServerOnly" } },
			resources = { { id = "Game.ValidResource", max = { value = 100 }, visibility = "ServerOnly" } },
			actions = {
				function(): ActionTypes.ActionDefinition
					return { id = "Game.ValidAction", visibility = "ServerOnly" }
				end,
			},
			replicationDomains = { TestUtils.createDomain("Game.Valid"), invalid },
		})
		expect(started).toBe(false)
		expectFailure(failure, "ReplicationDomain", domainCase.reason)
		expectUnpublished()
	end)
end

it("duplicate domain ids fail startup before publishing any catalog", function()
	local started: boolean, failure: StartupFailure? = Server.Init({
		replicationDomains = { TestUtils.createDomain("Game.Duplicate"), TestUtils.createDomain("Game.Duplicate") },
	})
	expect(started).toBe(false)
	expectFailure(failure, "ReplicationDomain", "DuplicateReplicationDomainId")
	expectUnpublished()
end)

it("malformed game domain catalogs fail startup rather than being ignored", function()
	local started: boolean, failure: StartupFailure? = Server.Init({ replicationDomains = false } :: any)
	expect(started).toBe(false)
	expectFailure(failure, "ReplicationDomain", "ReplicationDomainDefinitionsMustBeTable")
	expectUnpublished()
end)

type OtherCatalogCase = { name: string, config: ServerStartConfig, system: string, reason: string }
local otherCatalogFailures: { OtherCatalogCase } = {
	{
		name = "Controller",
		system = "Controller",
		reason = "DuplicateControllerKey",
		config = {
			controllers = {
				{
					key = "TagController",
					factory = function(_actor: ActorTypes.Actor): ActorTypes.Controller
						return { Destroy = function() end }
					end,
				},
			},
		},
	},
	{
		name = "Tag",
		system = "Tag",
		reason = "TagVisibilityInvalid",
		config = { tags = { { id = "Game.Invalid", duplicateBehavior = "Ignore", visibility = "Everyone" } :: any } },
	},
	{
		name = "Resource",
		system = "Resource",
		reason = "ResourceVisibilityInvalid",
		config = { resources = { { id = "Game.Invalid", max = { value = 100 }, visibility = "Everyone" } :: any } },
	},
	{
		name = "Action",
		system = "Action",
		reason = "ActionVisibilityInvalid",
		config = {
			actions = {
				function(): ActionTypes.ActionDefinition
					return { id = "Game.Invalid", visibility = "Everyone" } :: any
				end,
			},
		},
	},
}
for _, catalogCase: OtherCatalogCase in otherCatalogFailures do
	it("a failing " .. catalogCase.name .. " catalog also leaves valid replication domains unpublished", function()
		local config: ServerStartConfig = table.clone(catalogCase.config)
		config.replicationDomains = { TestUtils.createDomain("Game.Valid") }
		local started: boolean, failure: StartupFailure? = Server.Init(config)
		expect(started).toBe(false)
		expectFailure(failure, catalogCase.system, catalogCase.reason)
		expectUnpublished()
	end)
end

it("startup rejects an already published domain catalog without replacing it or publishing other catalogs", function()
	TestUtils.load({ TestUtils.createDomain("Game.Existing") })
	local existing: LoadedDomain = Domains.Get("Game.Existing") :: LoadedDomain
	local started: boolean, failure: StartupFailure? =
		Server.Init({ replicationDomains = { TestUtils.createDomain("Game.New") } })
	expect(started).toBe(false)
	expectFailure(failure, "Server", "CatalogAlreadyLoaded")
	expect(Controllers.IsLoaded()).toBe(false)
	expect(Tags.IsLoaded()).toBe(false)
	expect(Resources.IsLoaded()).toBe(false)
	expect(Actions.IsLoaded()).toBe(false)
	expect(Domains.Get("Game.Existing")).toBe(existing)
	expect(Domains.Get("Game.New")).toBeNil()
end)

it("a preloaded existing catalog prevents domain publication", function()
	local loaded: boolean, reason: string? = Controllers.Load({})
	expect(loaded).toBe(true)
	expect(reason).toBeNil()
	local started: boolean, failure: StartupFailure? =
		Server.Init({ replicationDomains = { TestUtils.createDomain("Game.New") } })
	expect(started).toBe(false)
	expectFailure(failure, "Server", "CatalogAlreadyLoaded")
	expect(Domains.IsLoaded()).toBe(false)
	expect(Domains.GetAll()).toEqual({})
end)

it("failed domain startup consumes the single initialization attempt without later publication", function()
	local invalid: any = TestUtils.createDomain("Game.Invalid")
	invalid.snapshot = nil
	local started: boolean, failure: StartupFailure? = Server.Init({ replicationDomains = { invalid } })
	expect(started).toBe(false)
	expectFailure(failure, "ReplicationDomain", "ReplicationDomainSnapshotMustBeFunction")
	local retried: boolean, retryFailure: StartupFailure? =
		Server.Init({ replicationDomains = { TestUtils.createDomain("Game.Valid") } })
	expect(retried).toBe(false)
	expectFailure(retryFailure, "Server", "ServerInitAlreadyAttempted")
	expectUnpublished()
end)

it("successful domain startup cannot be repeated to replace the immutable catalog", function()
	local started: boolean, failure: StartupFailure? =
		Server.Init({ replicationDomains = { TestUtils.createDomain("Game.Original") } })
	expect(started).toBe(true)
	expect(failure).toBeNil()
	local original: LoadedDomain = Domains.Get("Game.Original") :: LoadedDomain
	expect(original.id).toBe("Game.Original")
	local repeated: boolean, repeatFailure: StartupFailure? =
		Server.Init({ replicationDomains = { TestUtils.createDomain("Game.Replacement") } })
	expect(repeated).toBe(false)
	expectFailure(repeatFailure, "Server", "ServerInitAlreadyAttempted")
	expect(Domains.Get("Game.Original")).toBe(original)
	expect(Domains.Get("Game.Replacement")).toBeNil()
end)

it("startup owns domain source tables and subsequent source edits cannot change the loaded contract", function()
	local definition: ReplicationDomainDefinition = TestUtils.createDomain("Game.Original")
	local source: { ReplicationDomainDefinition } = { definition }
	local started: boolean, failure: StartupFailure? = Server.Init({ replicationDomains = source })
	expect(started).toBe(true)
	expect(failure).toBeNil()
	definition.id = "Game.Mutated"
	definition.audience = "Owner"
	table.clear(source)
	local original: LoadedDomain = Domains.Get("Game.Original") :: LoadedDomain
	expect(original.id).toBe("Game.Original")
	expect(original.audience).toBe("All")
	expect(Domains.Get("Game.Mutated")).toBeNil()
	expect(#Domains.GetAll()).toBe(1)
end)

it("startup does not invoke Actor snapshot or observation callbacks", function()
	local callbackCalls: number = 0
	local definition: ReplicationDomainDefinition = TestUtils.createDomain("Game.Static")
	definition.snapshot = function(_actor: ActorTypes.Actor): any
		callbackCalls += 1
		error("SnapshotCalledDuringStartup")
	end
	definition.observe = function(
		_actor: ActorTypes.Actor,
		_onCommitted: ReplicationTypes.ReplicationDomainOnCommitted
	): (() -> ())?
		callbackCalls += 1
		error("ObserveCalledDuringStartup")
	end
	local started: boolean, failure: StartupFailure? = Server.Init({ replicationDomains = { definition } })
	expect(started).toBe(true)
	expect(failure).toBeNil()
	expect(callbackCalls).toBe(0)
end)

it("N1 startup adds no RemoteEvent, RemoteFunction, or UnreliableRemoteEvent instances", function()
	local existingRemotes: { [Instance]: boolean } = {}
	for _, instance: Instance in game:GetDescendants() do
		if instance:IsA("RemoteEvent") or instance:IsA("RemoteFunction") or instance:IsA("UnreliableRemoteEvent") then
			existingRemotes[instance] = true
		end
	end
	local started: boolean, failure: StartupFailure? =
		Server.Init({ replicationDomains = { TestUtils.createDomain("Game.State") } })
	expect(started).toBe(true)
	expect(failure).toBeNil()
	for _, instance: Instance in game:GetDescendants() do
		if instance:IsA("RemoteEvent") or instance:IsA("RemoteFunction") or instance:IsA("UnreliableRemoteEvent") then
			expect(existingRemotes[instance]).toBe(true)
		end
	end
end)

it("Server test reset clears domains alongside the existing startup catalogs", function()
	local started: boolean, failure: StartupFailure? =
		Server.Init({ replicationDomains = { TestUtils.createDomain("Game.Old") } })
	expect(started).toBe(true)
	expect(failure).toBeNil()
	expect(Domains.IsLoaded()).toBe(true)
	Server._ResetForTests()
	expectUnpublished()
	local restarted: boolean, restartFailure: StartupFailure? =
		Server.Init({ replicationDomains = { TestUtils.createDomain("Game.New") } })
	expect(restarted).toBe(true)
	expect(restartFailure).toBeNil()
	expect(Domains.Get("Game.Old")).toBeNil()
	expect((Domains.Get("Game.New") :: LoadedDomain).id).toBe("Game.New")
end)
