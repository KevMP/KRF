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
local ProtocolTypes = require(KRF.shared.Networking.ProtocolTypes)
local Server = require(KRF.server)
local Controllers: ControllerTypes.ControllerRegistry = require(KRF.server.Controller.ControllerRegistry)
local Tags: TagTypes.TagRegistry = require(KRF.server.Tags.TagRegistry)
local Resources: ResourceTypes.ResourceRegistry = require(KRF.server.Resource.ResourceRegistry)
local Actions: ActionTypes.InternalActionRegistry = require(KRF.server.Action.ActionRegistry)
local Domains: ReplicationTypes.InternalReplicationDomainRegistry =
	require(KRF.server.Replication.ReplicationDomainRegistry)
local Networking = require(KRF.server.Networking.ServerNetworking)
local Transport = require(KRF.shared.Networking.Transport)

local originalControllers: typeof(Controllers.Load) = Controllers.Load
local originalTags: typeof(Tags.Load) = Tags.Load
local originalResources: typeof(Resources.Load) = Resources.Load
local originalActions: typeof(Actions.Publish) = Actions.Publish
local originalDomains: typeof(Domains.Publish) = Domains.Publish
local originalNetworking: typeof(Networking.Publish) = Networking.Publish

beforeEach(function()
	Server._ResetForTests()
end)
afterEach(function()
	Controllers.Load = originalControllers
	Tags.Load = originalTags
	Resources.Load = originalResources
	Actions.Publish = originalActions
	Domains.Publish = originalDomains
	Networking.Publish = originalNetworking
	Server._ResetForTests()
end)

type FailureCase = { system: string, inject: () -> () }
local cases: { FailureCase } = {
	{
		system = "Controller",
		inject = function(): ()
			Controllers.Load = function(_definitions: { ControllerTypes.ControllerDef }): (boolean, string?)
				return false, "PublicationFailure"
			end
		end,
	},
	{
		system = "Tag",
		inject = function(): ()
			Tags.Load = function(_definitions: { TagTypes.TagDefinition }): (boolean, string?)
				return false, "PublicationFailure"
			end
		end,
	},
	{
		system = "Resource",
		inject = function(): ()
			Resources.Load = function(_definitions: { ResourceTypes.ResourceDefinition }): (boolean, string?)
				return false, "PublicationFailure"
			end
		end,
	},
	{
		system = "Action",
		inject = function(): ()
			Actions.Publish = function(_catalog: ActionTypes.PreparedActionCatalog): (boolean, string?)
				return false, "PublicationFailure"
			end
		end,
	},
	{
		system = "ReplicationDomain",
		inject = function(): ()
			Domains.Publish = function(_catalog: ReplicationTypes.PreparedReplicationDomainCatalog): (boolean, string?)
				return false, "PublicationFailure"
			end
		end,
	},
}
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

for _, testCase: FailureCase in cases do
	it("rolls back every previously published catalog when " .. testCase.system .. " publication rejects", function()
		testCase.inject()
		local success: boolean, failure: ServerTypes.StartupFailure? = Server.Init({})
		expect(success).toBe(false)
		expect(failure).toEqual({ system = testCase.system, reason = "PublicationFailure" })
		expectUnpublished()
		local repeated: boolean, repeatFailure: ServerTypes.StartupFailure? = Server.Init({})
		expect(repeated).toBe(false)
		expect(repeatFailure).toEqual({ system = "Server", reason = "ServerInitAlreadyAttempted" })
	end)
end

it("keeps unexpected Networking activation failure observable after rolling back catalogs", function()
	Networking.Publish = function(_protocol: ProtocolTypes.PreparedProtocol): (boolean, string?)
		error("ActivationFailure")
	end
	local success: boolean, failure: ServerTypes.StartupFailure? = Server.Init({})
	expect(success).toBe(false)
	assert(failure ~= nil, "Expected a structured activation failure")
	expect(failure.system).toBe("Networking")
	expect(string.find(failure.reason, "ActivationFailure", 1, true) ~= nil).toBe(true)
	expectUnpublished()
end)
