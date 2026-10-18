--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF

local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local ServerTypes = require(KRF.server.types)
local ServerNetworkingTypes = require(KRF.server.Networking.types)
local ReplicationTypes = require(KRF.server.Replication.types)
local ControllerTypes = require(KRF.server.Controller.types)
local TagTypes = require(KRF.server.Tags.types)
local ResourceTypes = require(KRF.server.Resource.types)
local ActionTypes = require(KRF.server.Action.types)
local SharedNetworkingTypes = require(KRF.shared.Networking.types)
local Constants = require(KRF.shared.Networking.utils.ProtocolConstants)
local Server = require(KRF.server)
local Networking: ServerNetworkingTypes.ServerNetworking = require(KRF.server.Networking.ServerNetworking)
local Transport: SharedNetworkingTypes.Transport = require(KRF.shared.Networking.Transport)

local Domains: ReplicationTypes.InternalReplicationDomainRegistry =
	require(KRF.server.Replication.ReplicationDomainRegistry)

local Controllers: ControllerTypes.ControllerRegistry = require(KRF.server.Controller.ControllerRegistry)
local Tags: TagTypes.TagRegistry = require(KRF.server.Tags.TagRegistry)
local Resources: ResourceTypes.ResourceRegistry = require(KRF.server.Resource.ResourceRegistry)
local Actions: ActionTypes.ActionRegistry = require(KRF.server.Action.ActionRegistry)
local TestUtils = require(script.Parent.Parent.Utils.Replication.ReplicationDomainTestUtils)

local originalPrepare: typeof(Networking.Prepare) = Networking.Prepare
local originalPublish: typeof(Networking.Publish) = Networking.Publish
local collision: Folder? = nil

beforeEach(function()
	Server._ResetForTests()
	Networking._ResetForTests()
end)

afterEach(function()
	Networking.Prepare = originalPrepare
	Networking.Publish = originalPublish
	Server._ResetForTests()
	Networking._ResetForTests()

	if collision ~= nil then
		collision:Destroy()
		collision = nil
	end
end)

local function expectUnpublished(): ()
	expect(Server._IsInitialized()).toBe(false)
	expect(Networking._IsInitialized()).toBe(false)
	expect(Controllers.IsLoaded()).toBe(false)
	expect(Tags.IsLoaded()).toBe(false)
	expect(Resources.IsLoaded()).toBe(false)
	expect(Actions.IsLoaded()).toBe(false)
	expect(Domains.IsLoaded()).toBe(false)
end

it("prepares Networking from owned N1 metadata before publishing any catalog", function()
	local prepareCalls: number = 0

	Networking.Prepare = function(
		catalog: ReplicationTypes.PreparedReplicationDomainCatalog
	): (SharedNetworkingTypes.PreparedProtocol?, string?)
		prepareCalls += 1
		expectUnpublished()
		expect(table.isfrozen(catalog)).toBe(true)
		expect(catalog.definitionsById["Game.State"].state.kind).toBe("Struct")

		return originalPrepare(catalog)
	end

	local success: boolean, failure: ServerTypes.StartupFailure? =
		Server.Init({ replicationDomains = { TestUtils.createDomain("Game.State") } })

	expect(success).toBe(true)
	expect(failure).toBeNil()
	expect(prepareCalls).toBe(1)
	expect(Networking._IsInitialized()).toBe(true)
	local owned: SharedNetworkingTypes.OwnedTransport?, reason: string? = Transport.Locate(ReplicatedStorage)
	expect(reason).toBeNil()
	assert(owned ~= nil, "Expected server-owned framework transport")
	expect(#owned.root:GetDescendants()).toBe(2)
end)

for _, reason: string in
	{ "InvalidProtocolManifest", "BootstrapManifestTooLarge", "CodecCompilationFailure", "TransportConflict" }
do
	it("surfaces Networking " .. reason .. " without publishing any startup registry", function()
		Networking.Prepare = function(
			_catalog: ReplicationTypes.PreparedReplicationDomainCatalog
		): (SharedNetworkingTypes.PreparedProtocol?, string?)
			return nil, reason
		end

		local success: boolean, failure: ServerTypes.StartupFailure? =
			Server.Init({ replicationDomains = { TestUtils.createDomain("Game.State") } })

		expect(success).toBe(false)
		expect(failure).toEqual({ system = "Networking", reason = reason })
		expectUnpublished()
		expect(ReplicatedStorage:FindFirstChild(Transport.ROOT_NAME)).toBeNil()
	end)
end

it("rolls back catalog publication if transport activation fails after protocol preparation", function()
	local prepared: SharedNetworkingTypes.PreparedProtocol = {
		manifest = { version = Constants.PROTOCOL_VERSION, domains = {} },
		bootstrapBuffer = buffer.create(1),
		runtime = { domainsById = {}, domainsByCode = {} },
	}

	Networking.Prepare = function(
		_catalog: ReplicationTypes.PreparedReplicationDomainCatalog
	): (SharedNetworkingTypes.PreparedProtocol?, string?)
		return prepared, nil
	end

	Networking.Publish = function(protocol: SharedNetworkingTypes.PreparedProtocol): (boolean, string?)
		expect(protocol).toBe(prepared)

		return false, "TransportConflict"
	end

	local success: boolean, failure: ServerTypes.StartupFailure? =
		Server.Init({ replicationDomains = { TestUtils.createDomain("Game.State") } })

	expect(success).toBe(false)
	expect(failure).toEqual({ system = "Networking", reason = "TransportConflict" })
	expectUnpublished()
end)

it("detects a real reserved path collision without deleting the existing hierarchy", function()
	local reserved: Folder = Instance.new("Folder")
	reserved.Name = Transport.ROOT_NAME
	reserved.Parent = ReplicatedStorage
	collision = reserved

	local marker: StringValue = Instance.new("StringValue")
	marker.Value = "consumer-owned"
	marker.Parent = reserved
	local success: boolean, failure: ServerTypes.StartupFailure? = Server.Init({})
	expect(success).toBe(false)
	expect(failure).toEqual({ system = "Networking", reason = "TransportConflict" })
	expectUnpublished()
	expect(reserved.Parent).toBe(ReplicatedStorage)
	expect(marker.Value).toBe("consumer-owned")
	expect(#reserved:GetChildren()).toBe(1)
end)

it("keeps unexpected preparation failures observable with every startup registry unpublished", function()
	Networking.Prepare = function(
		_catalog: ReplicationTypes.PreparedReplicationDomainCatalog
	): (SharedNetworkingTypes.PreparedProtocol?, string?)
		error("UnexpectedNetworkingPreparationFailure")
	end

	local success: boolean? = nil
	local failure: ServerTypes.StartupFailure? = nil

	local completed: boolean, thrown: any = pcall(function()
		success, failure = Server.Init({})
	end)

	if completed then
		expect(success).toBe(false)
		assert(failure ~= nil, "Unexpected failure must be observable")
		expect(failure.system).toBe("Networking")
		expect(string.find(failure.reason, "UnexpectedNetworkingPreparationFailure", 1, true) ~= nil).toBe(true)
	else
		expect(string.find(tostring(thrown), "UnexpectedNetworkingPreparationFailure", 1, true) ~= nil).toBe(true)
	end

	expectUnpublished()
end)

it("keeps Server.Init non-yielding and one-shot while Networking starts", function()
	local success: boolean? = nil
	local failure: ServerTypes.StartupFailure? = nil

	local initThread: thread = coroutine.create(function()
		success, failure = Server.Init({})
	end)

	local completed: boolean = coroutine.resume(initThread)
	expect(completed).toBe(true)
	expect(coroutine.status(initThread)).toBe("dead")
	expect(success).toBe(true)
	expect(failure).toBeNil()
	expect(Networking._IsInitialized()).toBe(true)
	local secondSuccess: boolean, secondFailure: ServerTypes.StartupFailure? = Server.Init({})
	expect(secondSuccess).toBe(false)
	expect(secondFailure).toEqual({ system = "Server", reason = "ServerInitAlreadyAttempted" })
end)
