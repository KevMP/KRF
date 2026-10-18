--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local ActorTypes = require(KRF.server.Actor.types)
local TagTypes = require(KRF.server.Tags.types)
local ReplicationTypes = require(KRF.server.Replication.types)
local ServerTypes = require(KRF.server.Networking.types)
local SharedTypes = require(KRF.shared.Networking.types)
local Server = require(KRF.server)
local Actors: ActorTypes.ActorRuntime = require(KRF.server.Actor.ActorRuntime)
local Tags: TagTypes.TagRegistry = require(KRF.server.Tags.TagRegistry)
local Domains: ReplicationTypes.InternalReplicationDomainRegistry =
	require(KRF.server.Replication.ReplicationDomainRegistry)
local Builder: ReplicationTypes.BuiltInReplicationDomainBuilder =
	require(KRF.server.Replication.BuiltInReplicationDomains)
local Networking: ServerTypes.ServerNetworking = require(KRF.server.Networking.ServerNetworking)
local ProtocolCodec: SharedTypes.ProtocolCodec = require(KRF.shared.Networking.ProtocolCodec)
local Transport = require(KRF.shared.Networking.Transport)
local DomainUtils = require(script.Parent.Parent.Utils.Replication.ReplicationDomainTestUtils)

local prepared: SharedTypes.PreparedProtocol? = nil
local originalPrepare: typeof(Networking.Prepare) = Networking.Prepare
local originalBuild: typeof(Builder.Build) = Builder.Build
local models: { Model } = {}
local actors: { ActorTypes.Actor } = {}
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
	actors = {}
	for _, model: Model in models do
		model:Destroy()
	end
	models = {}
	Networking.Prepare = originalPrepare
	Builder.Build = originalBuild
	Server._ResetForTests()
end)

local function visible(id: string): TagTypes.TagDefinition
	return { id = id, visibility = "ClientVisible", duplicateBehavior = "Ignore" }
end

local function protocol(): SharedTypes.PreparedProtocol
	assert(prepared ~= nil, "Successful startup must prepare the ordinary N2 protocol")
	return prepared
end

for _, catalog: { TagTypes.TagDefinition } in
	{
		{},
		{ { id = "Private.Secret", visibility = "ServerOnly", duplicateBehavior = "Ignore" } },
	}
do
	it(
		"omits KRF.Tags and all Tag metadata when the visible catalog is empty (catalog size " .. #catalog .. ")",
		function()
			local started: boolean, failure: Server.StartupFailure? = Server.Init({ tags = catalog })
			expect(failure).toBeNil()
			expect(started).toBe(true)
			expect(Domains.GetAll()).toEqual({})
			expect(protocol().manifest.domains).toEqual({})
			local decoded: SharedTypes.ProtocolMessage?, reason: string? =
				ProtocolCodec.Decode(protocol().bootstrapBuffer)
			expect(reason).toBeNil()
			expect(decoded).toEqual({ kind = "Bootstrap", manifest = protocol().manifest })
		end
	)
end

it("publishes the exact built-in id through the ordinary registry beside a game domain", function()
	local started: boolean, failure: Server.StartupFailure? = Server.Init({
		tags = { visible("Status.Stunned") },
		replicationDomains = { DomainUtils.createDomain("Game.Custom") },
	})
	expect(failure).toBeNil()
	expect(started).toBe(true)
	expect(#Domains.GetAll()).toBe(2)
	local domain: ReplicationTypes.LoadedReplicationDomainDefinition? = Domains.Get("KRF.Tags")
	assert(domain ~= nil, "Expected generated built-in Tags domain")
	expect(domain.audience).toBe("All")
	expect(protocol().runtime.domainsById["KRF.Tags"].id).toBe("KRF.Tags")
	local root: Instance? = ReplicatedStorage:FindFirstChild(Transport.ROOT_NAME)
	assert(root ~= nil, "Expected normal framework transport")
	local children: { string } = {}
	for _, child: Instance in root:GetChildren() do
		table.insert(children, child.Name .. ":" .. child.ClassName)
	end
	table.sort(children)
	expect(children).toEqual({ "Reliable:RemoteEvent", "Unreliable:UnreliableRemoteEvent" })
end)

it(
	"bounds state by visible catalog size and uses only visible ids for map keys and exactly four semantic events",
	function()
		expect(Server.Init({
			tags = {
				visible("Status.Z"),
				{ id = "Private.Secret", visibility = "ServerOnly", duplicateBehavior = "Ignore" },
				visible("Status.A"),
			},
		})).toBe(true)
		local domain: ReplicationTypes.LoadedReplicationDomainDefinition? = Domains.Get("KRF.Tags")
		assert(domain ~= nil and domain.state.kind == "Map", "Expected bounded Tags Map")
		expect(domain.state.maxEntries).toBe(2)
		local key: SharedTypes.CompiledSchema = domain.state.key
		assert(key.kind == "Enum", "Expected visible-id Enum")
		expect(key.values).toEqual({ "Status.A", "Status.Z" })
		expect(key.ordinalsByValue["Private.Secret"]).toBeNil()
		local entry: SharedTypes.CompiledSchema = domain.state.value
		assert(entry.kind == "Struct", "Expected aggregate entry Struct")
		expect(#entry.fields).toBe(2)
		expect(entry.fieldsByName.stackCount.kind).toBe("U32")
		local expiry: SharedTypes.CompiledSchema = entry.fieldsByName.expiresAt
		assert(expiry.kind == "Optional", "Expected optional timing anchor")
		expect(expiry.inner.kind).toBe("F64")
		local eventIds: { string } = {}
		for _, event: ReplicationTypes.LoadedReplicationEventDefinition in domain.events do
			table.insert(eventIds, event.id)
			assert(event.payload.kind == "Enum", "Expected direct Tag-id event payload")
			expect(event.payload.values).toEqual({ "Status.A", "Status.Z" })
		end
		table.sort(eventIds)
		expect(eventIds).toEqual({ "Added", "Expired", "Refreshed", "Removed" })
	end
)

it("produces identical bootstrap bytes when declaration order or ServerOnly definitions change", function()
	local first: TagTypes.TagDefinition = visible("Status.Z")
	first.onTick = function() end
	first.properties = { WalkSpeed = { multiply = 2 } }
	expect(Server.Init({ tags = { first, visible("Status.A") } })).toBe(true)
	local previous: string = buffer.tostring(protocol().bootstrapBuffer)
	Server._ResetForTests()
	expect(Server.Init({
		tags = {
			visible("Status.A"),
			{
				id = "Private.NeverSerializeMe",
				visibility = "ServerOnly",
				duplicateBehavior = "Stack",
				maxStacks = 999,
			},
			visible("Status.Z"),
		},
	})).toBe(true)
	expect(buffer.tostring(protocol().bootstrapBuffer)).toBe(previous)
	local decoded: SharedTypes.ProtocolMessage?, reason: string? = ProtocolCodec.Decode(protocol().bootstrapBuffer)
	expect(reason).toBeNil()
	assert(decoded ~= nil and decoded.kind == "Bootstrap", "Expected a decoded real bootstrap")
	expect(decoded.manifest).toEqual(protocol().manifest)
end)

it("rejects a game collision before catalogs and networking become available", function()
	local started: boolean, failure: Server.StartupFailure? = Server.Init({
		tags = { visible("Status.Stunned") },
		replicationDomains = { DomainUtils.createDomain("KRF.Tags") },
	})
	expect(started).toBe(false)
	expect(failure).toEqual({ system = "ReplicationDomain", reason = "DuplicateReplicationDomainId" })
	expect(Server._IsInitialized()).toBe(false)
	expect(Tags.IsLoaded()).toBe(false)
	expect(Domains.IsLoaded()).toBe(false)
	expect(Networking._IsInitialized()).toBe(false)
	expect(ReplicatedStorage:FindFirstChild(Transport.ROOT_NAME)).toBeNil()
end)

it("keeps KRF.Tags reserved even when the built-in domain is omitted", function()
	local started: boolean, failure: Server.StartupFailure? = Server.Init({
		replicationDomains = { DomainUtils.createDomain("KRF.Tags") },
	})
	expect(started).toBe(false)
	assert(failure ~= nil, "Reserved-id collision must report a startup failure")
	expect(failure.system).toBe("ReplicationDomain")
	expect(failure.reason == "").toBe(false)
	expect(Server._IsInitialized()).toBe(false)
	expect(Domains.IsLoaded()).toBe(false)
	expect(ReplicatedStorage:FindFirstChild(Transport.ROOT_NAME)).toBeNil()
end)

it("builds the visible catalog once at startup while Actors attach and mutate independently", function()
	local builds: number = 0
	Builder.Build = function(
		catalogs: ReplicationTypes.ReplicationDomainBuildCatalogs
	): ({ ReplicationTypes.ReplicationDomainDefinition }?, string?)
		builds += 1
		expect(Tags.IsLoaded()).toBe(false)
		expect(Domains.IsLoaded()).toBe(false)
		return originalBuild(catalogs)
	end
	expect(Server.Init({ tags = { visible("Status.Stunned") } })).toBe(true)
	local domain: ReplicationTypes.LoadedReplicationDomainDefinition? = Domains.Get("KRF.Tags")
	assert(domain ~= nil, "Expected built-in domain")
	for _ = 1, 3 do
		local model: Model = Instance.new("Model")
		model.Parent = workspace
		table.insert(models, model)
		local actor: ActorTypes.Actor?, reason: string? = Actors.RegisterActor(model)
		assert(actor ~= nil, reason)
		table.insert(actors, actor)
		local controller: TagTypes.TagController? = actor:GetController("TagController") :: TagTypes.TagController?
		assert(controller ~= nil, "Expected automatic TagController installation")
		expect(controller:AddTag("Status.Stunned")).toBe(true)
		expect(Domains.Get("KRF.Tags")).toBe(domain)
	end
	expect(builds).toBe(1)
end)
