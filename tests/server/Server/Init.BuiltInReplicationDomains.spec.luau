--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF

local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local ServerTypes = require(KRF.server.types)
local ControllerTypes = require(KRF.server.Controller.types)
local TagTypes = require(KRF.server.Tags.types)
local ResourceTypes = require(KRF.server.Resource.types)
local ActionTypes = require(KRF.server.Action.types)
local ReplicationTypes = require(KRF.server.Replication.types)
local Server = require(KRF.server)
local Controllers: ControllerTypes.ControllerRegistry = require(KRF.server.Controller.ControllerRegistry)
local Tags: TagTypes.TagRegistry = require(KRF.server.Tags.TagRegistry)
local Resources: ResourceTypes.ResourceRegistry = require(KRF.server.Resource.ResourceRegistry)
local Actions: ActionTypes.ActionRegistry = require(KRF.server.Action.ActionRegistry)
local Domains: ReplicationTypes.InternalReplicationDomainRegistry =
	require(KRF.server.Replication.ReplicationDomainRegistry)
local Builder: ReplicationTypes.BuiltInReplicationDomainBuilder =
	require(KRF.server.Replication.BuiltInReplicationDomains)
local TestUtils = require(script.Parent.Parent.Utils.Replication.ReplicationDomainTestUtils)

type BuildCatalogs = ReplicationTypes.ReplicationDomainBuildCatalogs
type DomainDefinition = ReplicationTypes.ReplicationDomainDefinition
type StartupFailure = ServerTypes.StartupFailure

local originalBuild: typeof(Builder.Build) = Builder.Build

beforeEach(function()
	Builder.Build = originalBuild
	Server._ResetForTests()
end)

afterEach(function()
	Builder.Build = originalBuild
	Server._ResetForTests()
end)

local function expectUnpublished(): ()
	expect(Server._IsInitialized()).toBe(false)
	expect(Controllers.IsLoaded()).toBe(false)
	expect(Tags.IsLoaded()).toBe(false)
	expect(Resources.IsLoaded()).toBe(false)
	expect(Actions.IsLoaded()).toBe(false)
	expect(Domains.IsLoaded()).toBe(false)
	expect(Domains.GetAll()).toEqual({})
end

it("builds domains from validated owned catalog snapshots before publishing any registry", function()
	local tag: TagTypes.TagDefinition = {
		id = "Game.Grounded",
		duplicateBehavior = "Ignore",
		visibility = "ClientVisible",
		properties = { WalkSpeed = { multiply = 1.25 } },
	}
	local resource: ResourceTypes.ResourceDefinition = {
		id = "Game.Guard",
		max = { value = 100 },
		visibility = "ClientVisible",
	}
	local action: ActionTypes.ActionDefinition = {
		id = "Game.Block",
		visibility = "ClientVisible",
		requiredTags = { "Game.Grounded" },
		costs = { ["Game.Guard"] = 1 },
	}
	local buildCalls: number = 0
	Builder.Build = function(catalogs: BuildCatalogs): ({ DomainDefinition }?, string?)
		buildCalls += 1
		expectUnpublished()
		expect(table.isfrozen(catalogs)).toBe(true)
		expect(table.isfrozen(catalogs.tags)).toBe(true)
		expect(table.isfrozen(catalogs.resources)).toBe(true)
		expect(table.isfrozen(catalogs.actions)).toBe(true)
		expect(#catalogs.tags).toBe(2)
		expect(#catalogs.resources).toBe(1)
		expect(#catalogs.actions).toBe(1)
		expect(catalogs.tags[1].id).toBe("Game.Grounded")
		expect(catalogs.tags[1].visibility).toBe("ClientVisible")
		expect(catalogs.tags[2].visibility).toBe("ServerOnly")
		local properties: { [string]: TagTypes.PropertyModifier } =
			catalogs.tags[1].properties :: { [string]: TagTypes.PropertyModifier }
		expect(properties.WalkSpeed.multiply).toBe(1.25)
		expect(table.isfrozen(catalogs.tags[1])).toBe(true)
		expect(table.isfrozen(properties)).toBe(true)
		expect(table.isfrozen(properties.WalkSpeed)).toBe(true)
		expect(catalogs.resources[1].max.value).toBe(100)
		expect(catalogs.resources[1].min.value).toBe(0)
		expect(catalogs.resources[1].autoAssign).toBe(false)
		expect(catalogs.resources[1].visibility).toBe("ClientVisible")
		expect(table.isfrozen(catalogs.resources[1])).toBe(true)
		expect(table.isfrozen(catalogs.resources[1].max)).toBe(true)
		expect(catalogs.actions[1].id).toBe("Game.Block")
		expect(catalogs.actions[1].visibility).toBe("ClientVisible")
		expect(catalogs.actions[1].autoGrant).toBe(false)
		expect(catalogs.actions[1].requiredTags).toEqual({ "Game.Grounded" })
		expect(catalogs.actions[1].costs).toEqual({ ["Game.Guard"] = 1 })
		expect(table.isfrozen(catalogs.actions[1])).toBe(true)
		expect(table.isfrozen(catalogs.actions[1].requiredTags)).toBe(true)
		expect(catalogs.tags[1]).never.toBe(tag)
		expect(catalogs.resources[1]).never.toBe(resource)
		expect(catalogs.actions[1]).never.toBe(action)
		return { TestUtils.createDomain("KRF.Generated") }, nil
	end
	local started: boolean, failure: StartupFailure? = Server.Init({
		tags = {
			tag,
			{ id = "Game.Private", duplicateBehavior = "Ignore", visibility = "ServerOnly" },
		},
		resources = { resource },
		actions = {
			function(): ActionTypes.ActionDefinition
				-- Consumer factories run after supporting catalogs are owned.
				tag.id = "Game.Mutated"
				(tag.properties :: { [string]: TagTypes.PropertyModifier }).WalkSpeed.multiply = 9
				resource.max.value = -1
				return action
			end,
		},
		replicationDomains = { TestUtils.createDomain("Game.State") },
	})
	expect(started).toBe(true)
	expect(failure).toBeNil()
	expect(buildCalls).toBe(1)
	expect(Domains.GetAll()[1].id).toBe("KRF.Generated")
	expect(Domains.GetAll()[2].id).toBe("Game.State")
	expect(#Domains.GetAll()).toBe(2)
	expect(table.isfrozen(tag)).toBe(false)
	expect(table.isfrozen(resource.max)).toBe(false)
	expect(table.isfrozen(action)).toBe(false)
end)

it("validates generated and game domains together and rejects shared ids before publication", function()
	Builder.Build = function(_catalogs: BuildCatalogs): ({ DomainDefinition }?, string?)
		return { TestUtils.createDomain("KRF.Shared") }, nil
	end
	local started: boolean, failure: StartupFailure? = Server.Init({
		replicationDomains = { TestUtils.createDomain("KRF.Shared") },
	})
	expect(started).toBe(false)
	expect(failure).toEqual({ system = "ReplicationDomain", reason = "DuplicateReplicationDomainId" })
	expectUnpublished()
end)

it("rejects unknown schema fields in generated domains before publishing catalogs", function()
	Builder.Build = function(_catalogs: BuildCatalogs): ({ DomainDefinition }?, string?)
		local domain: DomainDefinition = TestUtils.createDomain("KRF.Invalid")
		domain.state = { kind = "U8", futureSemantics = true } :: any
		return { domain }, nil
	end
	local started: boolean, failure: StartupFailure? = Server.Init({})
	expect(started).toBe(false)
	expect(failure).toEqual({ system = "ReplicationDomain", reason = "SchemaFieldUnknown" })
	expectUnpublished()
end)

type InvalidBuildCase = { name: string, result: any, buildReason: string?, reason: string }
local invalidBuilds: { InvalidBuildCase } = {
	{ name = "explicit failure", result = nil, buildReason = "BuiltInSchemaInvalid", reason = "BuiltInSchemaInvalid" },
	{ name = "failure without a reason", result = nil, reason = "ReplicationDomainBuildFailed" },
	{ name = "non-table catalog", result = false, reason = "ReplicationDomainDefinitionsMustBeTable" },
	{
		name = "sparse catalog",
		result = { [2] = TestUtils.createDomain("KRF.Sparse") },
		reason = "ReplicationDomainDefinitionsMustBeArray",
	},
	{
		name = "dictionary catalog",
		result = { domain = TestUtils.createDomain("KRF.Dictionary") },
		reason = "ReplicationDomainDefinitionsMustBeArray",
	},
}
for _, buildCase: InvalidBuildCase in invalidBuilds do
	it("a builder " .. buildCase.name .. " leaves every startup catalog unpublished", function()
		Builder.Build = function(_catalogs: BuildCatalogs): ({ DomainDefinition }?, string?)
			return buildCase.result, buildCase.buildReason
		end
		local started: boolean, failure: StartupFailure? = Server.Init({})
		expect(started).toBe(false)
		expect(failure).toEqual({ system = "ReplicationDomain", reason = buildCase.reason })
		expectUnpublished()
	end)
end

type InvalidCatalogCase = { name: string, config: ServerTypes.ServerStartConfig, reason: string }
local invalidCatalogs: { InvalidCatalogCase } = {
	{
		name = "Tag",
		config = { tags = { { id = "Game.Invalid", duplicateBehavior = "Ignore", visibility = "Everyone" } :: any } },
		reason = "TagVisibilityInvalid",
	},
	{
		name = "Resource",
		config = { resources = { { id = "Game.Invalid", max = { value = 100 }, visibility = "Everyone" } :: any } },
		reason = "ResourceVisibilityInvalid",
	},
	{
		name = "Action",
		config = {
			actions = {
				function(): ActionTypes.ActionDefinition
					return { id = "Game.Invalid", visibility = "Everyone" } :: any
				end,
			},
		},
		reason = "ActionVisibilityInvalid",
	},
}
for _, catalogCase: InvalidCatalogCase in invalidCatalogs do
	it("rejects an invalid " .. catalogCase.name .. " catalog before calling the domain builder", function()
		local buildCalls: number = 0
		Builder.Build = function(_catalogs: BuildCatalogs): ({ DomainDefinition }?, string?)
			buildCalls += 1
			return {}, nil
		end
		local started: boolean, failure: StartupFailure? = Server.Init(catalogCase.config)
		expect(started).toBe(false)
		expect(failure).toEqual({ system = catalogCase.name, reason = catalogCase.reason })
		expect(buildCalls).toBe(0)
		expectUnpublished()
	end)
end
