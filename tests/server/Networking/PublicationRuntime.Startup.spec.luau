--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF

local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local ActorTypes = require(KRF.server.Actor.types)
local PublicationTypes = require(KRF.server.Networking.PublicationTypes)
local NetworkingTypes = require(KRF.server.Networking.types)
local ServerTypes = require(KRF.server.types)
local ReplicationTypes = require(KRF.server.Replication.types)
local ProtocolTypes = require(KRF.shared.Networking.ProtocolTypes)
local SchemaTypes = require(KRF.shared.Networking.types)
local Schema: SchemaTypes.Schema = require(KRF.shared.Networking.Schema)
local ActorEntity = require(KRF.server.Actor.ActorEntity)
local ActorRuntime: ActorTypes.ActorRuntime = require(KRF.server.Actor.ActorRuntime)
local Networking: NetworkingTypes.ServerNetworking = require(KRF.server.Networking.ServerNetworking)
local Server = require(KRF.server)
local TestUtils = require(script.Parent.Parent.Utils.Networking.PublicationTestUtils)

local model: Model? = nil
local originalPublish: typeof(Networking.Publish) = Networking.Publish

beforeEach(function()
	Server._ResetForTests()
end)

afterEach(function()
	Networking.Publish = originalPublish
	Server._ResetForTests()
	if model ~= nil then
		model:Destroy()
		model = nil
	end
end)

it("loads the real domain before RegisterActor returns and publishes its immediate mutation", function()
	local domain: TestUtils.DomainFixture =
		TestUtils.createDomain("Game.Stamina", Schema.Struct({ current = Schema.U8 }), { current = 100 })
	local started: boolean, failure: ServerTypes.StartupFailure? =
		Server.Init({ replicationDomains = { domain.definition } })
	expect(started).toBe(true)
	expect(failure).toBeNil()
	local publication: PublicationTypes.Runtime? = Networking._GetPublicationRuntimeForTests()
	assert(publication ~= nil, "Server.Init must install the real N3 runtime from its loaded catalog")
	local commits: { PublicationTypes.Commit } = {}
	publication:ObserveCommits(function(commit: PublicationTypes.Commit): ()
		table.insert(commits, commit)
	end)
	model = Instance.new("Model")
	model.Parent = workspace
	local actor: ActorTypes.Actor?, reason: string? = ActorRuntime.RegisterActor(model)
	expect(reason).toBeNil()
	assert(actor ~= nil, "Expected registered Actor")
	expect(domain.snapshotCalls).toBe(1)
	expect(domain.callbacks[actor]).never.toBeNil()
	expect(publication:CaptureBaseline(actor)).toEqual({
		sequence = 0,
		domains = { ["Game.Stamina"] = { current = 100 } },
	})
	domain.value.current = 80
	domain.callbacks[actor]()
	expect(#commits).toBe(1)
	expect(commits[1].actor).toBe(actor)
	expect(commits[1].sequence).toBe(1)
	expect(commits[1].patches).toEqual({
		{
			domainId = "Game.Stamina",
			patch = { kind = "Struct", fields = { current = { kind = "Replace", value = 80 } } },
		},
	})
	expect(publication:CaptureBaseline(actor)).toEqual({
		sequence = 1,
		domains = { ["Game.Stamina"] = { current = 80 } },
	})
end)

it("server reset destroys its installed runtime and disconnects a live domain", function()
	local domain: TestUtils.DomainFixture = TestUtils.createDomain("Game.Stamina", Schema.U8, 100)
	expect(Server.Init({ replicationDomains = { domain.definition } })).toBe(true)
	local publication: PublicationTypes.Runtime? = Networking._GetPublicationRuntimeForTests()
	assert(publication ~= nil, "Expected startup-owned publication runtime")
	model = Instance.new("Model")
	model.Parent = workspace
	local actor: ActorTypes.Actor?, reason: string? = ActorRuntime.RegisterActor(model)
	expect(reason).toBeNil()
	assert(actor ~= nil, "Expected registered Actor")
	local commits: { PublicationTypes.Commit } = {}
	publication:ObserveCommits(function(commit: PublicationTypes.Commit): ()
		table.insert(commits, commit)
	end)
	Server._ResetForTests()
	expect(Networking._GetPublicationRuntimeForTests()).toBeNil()
	expect(domain.disconnectCalls).toBe(1)
	expect(publication:GetAttachedActors()).toEqual({})
	domain.value = 80
	domain.callbacks[actor]()
	expect(commits).toEqual({})
end)

it("rolls back an installed runtime and its observers when startup fails after publication", function()
	local domain: TestUtils.DomainFixture = TestUtils.createDomain("Game.Stamina", Schema.U8, 100)
	local attached: ActorTypes.Actor = ActorEntity.new()
	local publishedRuntime: PublicationTypes.Runtime? = nil
	local commits: { PublicationTypes.Commit } = {}
	Networking.Publish = function(protocol: ProtocolTypes.PreparedProtocol): (boolean, string?)
		local success: boolean, reason: string? = originalPublish(protocol)
		if not success then
			return false, reason
		end
		publishedRuntime = Networking._GetPublicationRuntimeForTests()
		assert(publishedRuntime ~= nil, "Publication runtime must be installed during Networking startup")
		publishedRuntime:ObserveCommits(function(commit: PublicationTypes.Commit): ()
			table.insert(commits, commit)
		end)
		local attachedSuccessfully: boolean, attachReason: string? = publishedRuntime:AttachActor(attached)
		expect(attachedSuccessfully).toBe(true)
		expect(attachReason).toBeNil()
		return false, "ForcedPublicationRollback"
	end
	local started: boolean, failure: ServerTypes.StartupFailure? =
		Server.Init({ replicationDomains = { domain.definition } })
	expect(started).toBe(false)
	expect(failure).toEqual({ system = "Networking", reason = "ForcedPublicationRollback" })
	expect(Networking._GetPublicationRuntimeForTests()).toBeNil()
	expect(domain.disconnectCalls).toBe(1)
	assert(publishedRuntime ~= nil, "Expected runtime created during failed startup")
	expect(publishedRuntime:GetAttachedActors()).toEqual({})
	domain.value = 80
	domain.callbacks[attached]()
	expect(commits).toEqual({})
end)

it("rejects an impossible semantic event size through the real startup path", function()
	local impossible: ReplicationTypes.ReplicationDomainDefinition = {
		id = "Game.HugeEvent",
		state = Schema.Struct({}),
		events = { { id = "TooLarge", payload = Schema.Array(Schema.U8, 1000000) } },
		snapshot = function(_actor: ActorTypes.Actor): any
			return {}
		end,
	}
	local started: boolean, failure: ServerTypes.StartupFailure? = Server.Init({ replicationDomains = { impossible } })
	expect(started).toBe(false)
	expect(failure).toEqual({ system = "Networking", reason = "PublicationEventTooLarge:Game.HugeEvent:TooLarge" })
	expect(Networking._IsInitialized()).toBe(false)
	expect(Networking._GetPublicationRuntimeForTests()).toBeNil()
end)
