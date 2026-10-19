--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local ActorTypes = require(KRF.server.Actor.types)
local ResourceTypes = require(KRF.server.Resource.types)
local ReplicationTypes = require(KRF.server.Replication.types)
local NetworkingTypes = require(KRF.server.Networking.types)
local SharedTypes = require(KRF.shared.Networking.types)
local Server = require(KRF.server)
local Actors: ActorTypes.ActorRuntime = require(KRF.server.Actor.ActorRuntime)
local Resources: ResourceTypes.ResourceRegistry = require(KRF.server.Resource.ResourceRegistry)

local Domains: ReplicationTypes.InternalReplicationDomainRegistry =
	require(KRF.server.Replication.ReplicationDomainRegistry)

local Builder: ReplicationTypes.BuiltInReplicationDomainBuilder =
	require(KRF.server.Replication.BuiltInReplicationDomains)

local Networking: NetworkingTypes.ServerNetworking = require(KRF.server.Networking.ServerNetworking)
local ProtocolCodec: SharedTypes.ProtocolCodec = require(KRF.shared.Networking.ProtocolCodec)
local Transport = require(KRF.shared.Networking.Transport)
local DomainUtils = require(script.Parent.Parent.Utils.Replication.ReplicationDomainTestUtils)

local originalPrepare = Networking.Prepare
local originalBuild = Builder.Build
local prepared: SharedTypes.PreparedProtocol? = nil
local actors: { ActorTypes.Actor } = {}
local models: { Model } = {}

beforeEach(function()
	Server._ResetForTests()
	prepared = nil

	Networking.Prepare = function(
		catalog: ReplicationTypes.PreparedReplicationDomainCatalog
	): (SharedTypes.PreparedProtocol?, string?)
		local protocol: SharedTypes.PreparedProtocol?, reason: string? = originalPrepare(catalog)
		prepared = protocol

		return protocol, reason
	end
end)

afterEach(function()
	for _, actor: ActorTypes.Actor in actors do
		Actors.UnregisterActor(actor)
	end

	for _, model: Model in models do
		model:Destroy()
	end

	actors = {}
	models = {}
	Networking.Prepare = originalPrepare
	Builder.Build = originalBuild
	Server._ResetForTests()
end)

local function visible(id: string): ResourceTypes.ResourceDefinition
	return { id = id, visibility = "ClientVisible", max = { value = 100 } }
end

local function protocol(): SharedTypes.PreparedProtocol
	assert(prepared ~= nil, "Successful normal startup must prepare N2")

	return prepared
end

for _, catalog: { ResourceTypes.ResourceDefinition } in
	{
		{},
		{ { id = "Private.Secret", visibility = "ServerOnly", max = { value = 50 } } },
	}
do
	it("omits domain and Resource metadata with no visible definitions (catalog size " .. #catalog .. ")", function()
		local started: boolean, failure: Server.StartupFailure? = Server.Init({ resources = catalog })
		expect(failure).toBeNil()
		expect(started).toBe(true)
		expect(Domains.GetAll()).toEqual({})
		expect(protocol().manifest.domains).toEqual({})
		local decoded: SharedTypes.ProtocolMessage?, reason: string? = ProtocolCodec.Decode(protocol().bootstrapBuffer)
		expect(reason).toBeNil()
		expect(decoded).toEqual({ kind = "Bootstrap", manifest = protocol().manifest })
	end)
end

it("registers the state-only All-audience domain beside Tags and game domains with only ordinary Remotes", function()
	local started: boolean, failure: Server.StartupFailure? = Server.Init({
		resources = { visible("Resource.Mana") },
		tags = { { id = "Status.Ready", visibility = "ClientVisible", duplicateBehavior = "Ignore" } },
		replicationDomains = { DomainUtils.createDomain("Game.Custom") },
	})

	expect(failure).toBeNil()
	expect(started).toBe(true)
	expect(#Domains.GetAll()).toBe(3)
	local domain: ReplicationTypes.LoadedReplicationDomainDefinition? = Domains.Get("KRF.Resources")
	assert(domain ~= nil, "Expected exact generated Resources id")
	expect(domain.audience).toBe("All")
	expect(domain.events).toEqual({})
	expect(protocol().runtime.domainsById["KRF.Resources"].id).toBe("KRF.Resources")
	local root: Instance? = ReplicatedStorage:FindFirstChild(Transport.ROOT_NAME)
	assert(root ~= nil, "Expected native transport installation")
	local remotes: { string } = {}

	for _, child: Instance in root:GetChildren() do
		table.insert(remotes, child.Name .. ":" .. child.ClassName)
	end

	table.sort(remotes)
	expect(remotes).toEqual({ "Reliable:RemoteEvent", "Unreliable:UnreliableRemoteEvent" })
end)

it("bounds the assigned-resource Map by visible catalog count with finite F64 anchors and optional rate", function()
	expect(Server.Init({
		resources = {
			visible("Resource.Z"),
			{ id = "Private.Secret", visibility = "ServerOnly", max = { value = 50 } },
			visible("Resource.A"),
		},
	})).toBe(true)

	local domain: ReplicationTypes.LoadedReplicationDomainDefinition? = Domains.Get("KRF.Resources")
	assert(domain ~= nil and domain.state.kind == "Map", "Expected bounded Resources Map")
	expect(domain.state.maxEntries).toBe(2)
	local key: SharedTypes.CompiledSchema = domain.state.key
	assert(key.kind == "Enum", "Expected startup visible-id Enum")
	expect(key.values).toEqual({ "Resource.A", "Resource.Z" })
	expect(key.ordinalsByValue["Private.Secret"]).toBeNil()
	local entry: SharedTypes.CompiledSchema = domain.state.value
	assert(entry.kind == "Struct", "Expected interpolation anchor")
	expect(#entry.fields).toBe(5)

	for _, name: string in { "anchorValue", "anchorTime", "min", "max" } do
		expect(entry.fieldsByName[name].kind).toBe("F64")
	end

	local rate: SharedTypes.CompiledSchema = entry.fieldsByName.regenRate
	assert(rate.kind == "Optional", "No regen differs from a resolved zero rate")
	expect(rate.inner.kind).toBe("F64")
end)

it(
	"keeps bootstrap bytes identical across declaration order, private catalog and server-only metadata changes",
	function()
		expect(Server.Init({ resources = { visible("Resource.Z"), visible("Resource.A") } })).toBe(true)
		local previous: string = buffer.tostring(protocol().bootstrapBuffer)
		Server._ResetForTests()

		local changed: ResourceTypes.ResourceDefinition = visible("Resource.A")
		changed.max = { propertyName = "SecretImplementation", defaultBaseValue = 900 }
		changed.regen = { rate = { value = 7 } }
		changed.autoAssign = true

		expect(Server.Init({
			resources = {
				changed,
				{ id = "Private.NeverSerializeMe", visibility = "ServerOnly", max = { value = 99 } },
				visible("Resource.Z"),
			},
		})).toBe(true)

		expect(buffer.tostring(protocol().bootstrapBuffer)).toBe(previous)
		local decoded: SharedTypes.ProtocolMessage?, reason: string? = ProtocolCodec.Decode(protocol().bootstrapBuffer)
		expect(reason).toBeNil()
		expect(decoded).toEqual({ kind = "Bootstrap", manifest = protocol().manifest })
	end
)

for _, enabled: boolean in { false, true } do
	it("reserves KRF.Resources before any publication even when enabled=" .. tostring(enabled), function()
		local started: boolean, failure: Server.StartupFailure? = Server.Init({
			resources = if enabled then { visible("Resource.Mana") } else {},
			replicationDomains = { DomainUtils.createDomain("KRF.Resources") },
		})

		expect(started).toBe(false)
		expect(failure).toEqual({ system = "ReplicationDomain", reason = "DuplicateReplicationDomainId" })
		expect(Server._IsInitialized()).toBe(false)
		expect(Resources.IsLoaded()).toBe(false)
		expect(Domains.IsLoaded()).toBe(false)
		expect(Networking._IsInitialized()).toBe(false)
		expect(ReplicatedStorage:FindFirstChild(Transport.ROOT_NAME)).toBeNil()
	end)
end

it(
	"builds visible definitions once from staged catalogs before registries publish, independent of Actor count",
	function()
		local builds: number = 0

		Builder.Build = function(
			catalogs: ReplicationTypes.ReplicationDomainBuildCatalogs
		): ({ ReplicationTypes.ReplicationDomainDefinition }?, string?)
			builds += 1
			expect(Resources.IsLoaded()).toBe(false)
			expect(Domains.IsLoaded()).toBe(false)
			expect(table.isfrozen(catalogs.resources)).toBe(true)
			expect(catalogs.resources[1].min.value).toBe(0)

			return originalBuild(catalogs)
		end

		expect(Server.Init({ resources = { visible("Resource.Mana") } })).toBe(true)
		local domain: ReplicationTypes.LoadedReplicationDomainDefinition? = Domains.Get("KRF.Resources")
		assert(domain ~= nil, "Expected startup-generated domain")

		for _ = 1, 3 do
			local model: Model = Instance.new("Model")
			model.Parent = workspace
			table.insert(models, model)
			local actor: ActorTypes.Actor?, reason: string? = Actors.RegisterActor(model)
			assert(actor ~= nil, reason)
			table.insert(actors, actor)

			local controller: ResourceTypes.ResourceController =
				actor:GetController("ResourceController") :: ResourceTypes.ResourceController

			expect(controller:AddResource("Resource.Mana")).toBe(true)
			expect(Domains.Get("KRF.Resources")).toBe(domain)
		end

		expect(builds).toBe(1)
	end
)
