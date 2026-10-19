--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local ActionTypes = require(KRF.server.Action.types)
local ActorTypes = require(KRF.server.Actor.types)
local ResourceTypes = require(KRF.server.Resource.types)
local NetworkingTypes = require(KRF.server.Networking.types)
local SharedTypes = require(KRF.shared.Networking.types)
local Networking: NetworkingTypes.ServerNetworking = require(KRF.server.Networking.ServerNetworking)
local GoodSignal: any = require(KRF.shared.Signal.GoodSignal)
local ActionUtils = require(script.Parent.Parent.Utils.Action.ActionResourceTestUtils)
local ResourceUtils = require(script.Parent.Parent.Utils.Networking.ResourcesReplicationTestUtils)

local originalConnect: any = GoodSignal.Connect
local originalFire: any = GoodSignal.Fire

beforeEach(ActionUtils.reset)

afterEach(function()
	GoodSignal.Connect = originalConnect
	GoodSignal.Fire = originalFire
	ActionUtils.cleanup()
end)

it("commits all real Action costs as one private touched set and publishes before ActionStarted Fire", function()
	local startedSignal: any = nil
	local connecting: boolean = false

	GoodSignal.Connect = function(self: any, callback: any): any
		if connecting then
			startedSignal = self
		end

		return originalConnect(self, callback)
	end

	ActionUtils.initialize({
		{
			id = "Action.Cast",
			visibility = "ServerOnly",
			autoGrant = true,
			costs = { ["Resource.Mana"] = 15, ["Resource.Stamina"] = 5 },
		},
	}, ResourceUtils.catalog())

	local actor: ActorTypes.Actor, actions: ActionTypes.ActionController, resources: ResourceTypes.ResourceController =
		ActionUtils.registerActor()

	local internal: ResourceTypes.InternalResourceController = resources :: ResourceTypes.InternalResourceController
	local publication: NetworkingTypes.PublicationRuntime? = Networking._GetPublicationRuntimeForTests()
	assert(publication ~= nil, "Normal startup must own N3 publication")
	local commits: { NetworkingTypes.PublicationCommit } = {}
	local touched: { { ResourceTypes.ResourceMutation } } = {}
	local atStarted: NetworkingTypes.PublicationBaseline? = nil
	local commitsAtStarted: number = 0

	publication:ObserveCommits(function(commit: NetworkingTypes.PublicationCommit)
		table.insert(commits, commit)
	end)

	internal:_observeMutations({
		Commit = function(mutations: { ResourceTypes.ResourceMutation })
			table.insert(touched, mutations)
		end,
		Dispatch = function() end,
	})

	connecting = true
	actions.OnActionStarted:Connect(function() end)
	connecting = false
	GoodSignal.Connect = originalConnect

	GoodSignal.Fire = function(self: any, ...: any)
		if self == startedSignal then
			atStarted = publication:CaptureBaseline(actor)
			commitsAtStarted = #commits
		end

		originalFire(self, ...)
	end

	local result: ActionTypes.ActionRequestResult = actions:RequestAction("Action.Cast")
	expect(result.accepted).toBe(true)
	expect(resources:GetCurrent("Resource.Mana")).toBe(25)
	expect(resources:GetCurrent("Resource.Stamina")).toBe(15)

	expect(touched).toEqual({
		{
			{ resourceId = "Resource.Mana", kind = "Discrete" },
			{ resourceId = "Resource.Stamina", kind = "Discrete" },
		},
	})

	expect(commitsAtStarted).toBe(1)
	assert(atStarted ~= nil, "Expected a snapshot at actual ActionStarted Fire invocation")
	expect(atStarted.sequence).toBe(1)
	expect(atStarted.domains["KRF.Resources"].value["Resource.Mana"].anchorValue).toBe(25)
	expect(atStarted.domains["KRF.Resources"].value["Resource.Stamina"].anchorValue).toBe(15)
	expect(#commits).toBe(1)
	expect(commits[1].events).toEqual({})
end)

it(
	"uses ordinary Actor commit grouping for several Resource costs without Action metadata in Resource state",
	function()
		ActionUtils.initialize({
			{
				id = "Action.Cast",
				visibility = "ServerOnly",
				autoGrant = true,
				costs = { ["Resource.Mana"] = 15, ["Resource.Stamina"] = 5 },
			},
		}, ResourceUtils.catalog())

		local actor: ActorTypes.Actor, actions: ActionTypes.ActionController = ActionUtils.registerActor()
		local publication: NetworkingTypes.PublicationRuntime? = Networking._GetPublicationRuntimeForTests()
		assert(publication ~= nil, "Expected normal N3 installation")
		local commits: { NetworkingTypes.PublicationCommit } = {}

		publication:ObserveCommits(function(commit: NetworkingTypes.PublicationCommit)
			table.insert(commits, commit)
		end)

		publication:WithActorCommit(actor, function()
			expect(actions:RequestAction("Action.Cast").accepted).toBe(true)
			expect(commits).toEqual({})
		end)

		expect(#commits).toBe(1)
		expect(#commits[1].patches).toBe(1)
		expect(commits[1].patches[1].domainId).toBe("KRF.Resources")
		local patch: SharedTypes.ActorPatch = commits[1].patches[1].patch
		assert(patch.kind == "Map", "Costs are ordinary resulting Resource Map truth")
		expect(patch.entries["Resource.Mana"].anchorValue).toBe(25)
		expect(patch.entries["Resource.Stamina"].anchorValue).toBe(15)
		expect(patch.entries["Resource.Mana"].cost).toBeNil()
		expect(patch.entries["Resource.Mana"].actionId).toBeNil()
	end
)

it("publishes final cost, Tag-derived bounds and rate together without intermediate Resource anchors", function()
	ActionUtils.initialize(
		{
			{
				id = "Action.Cast",
				visibility = "ServerOnly",
				autoGrant = true,
				costs = { ["Resource.Mana"] = 15 },
				activeTags = { "Status.Capacity" },
			},
		},
		ResourceUtils.catalog(),
		{
			{
				id = "Status.Capacity",
				visibility = "ServerOnly",
				duplicateBehavior = "Ignore",
				properties = { ManaMax = { set = 20 }, ManaRegen = { set = 25 } },
			},
		}
	)

	local actor: ActorTypes.Actor, actions: ActionTypes.ActionController, resources: ResourceTypes.ResourceController =
		ActionUtils.registerActor()

	local publication: NetworkingTypes.PublicationRuntime? = Networking._GetPublicationRuntimeForTests()
	assert(publication ~= nil, "Expected normal N3 installation")
	local commits: { NetworkingTypes.PublicationCommit } = {}

	publication:ObserveCommits(function(commit: NetworkingTypes.PublicationCommit)
		table.insert(commits, commit)
	end)

	expect(actions:RequestAction("Action.Cast").accepted).toBe(true)
	expect(resources:GetCurrent("Resource.Mana")).toBe(20)
	expect(resources:GetMax("Resource.Mana")).toBe(20)
	expect(#commits).toBe(1)
	expect(commits[1].actor).toBe(actor)
	expect(#commits[1].patches).toBe(1)
	local patch: SharedTypes.ActorPatch = commits[1].patches[1].patch
	assert(patch.kind == "Map", "Expected one resulting Resource Map patch")
	expect(patch.entries["Resource.Mana"].anchorValue).toBe(20)
	expect(patch.entries["Resource.Mana"].max).toBe(20)
	expect(patch.entries["Resource.Mana"].regenRate).toBe(25)
	expect(patch.entries["Resource.Stamina"]).toBeNil()
	expect(commits[1].events).toEqual({})
end)

it("creates no Resource publication work when real Action cost planning rejects atomically", function()
	ActionUtils.initialize({
		{
			id = "Action.Cast",
			visibility = "ServerOnly",
			autoGrant = true,
			costs = { ["Resource.Mana"] = 500, ["Resource.Stamina"] = 5 },
		},
	}, ResourceUtils.catalog())

	local actor: ActorTypes.Actor, actions: ActionTypes.ActionController, resources: ResourceTypes.ResourceController =
		ActionUtils.registerActor()

	local publication: NetworkingTypes.PublicationRuntime? = Networking._GetPublicationRuntimeForTests()
	assert(publication ~= nil, "Expected normal N3 installation")
	local before: NetworkingTypes.PublicationBaseline? = publication:CaptureBaseline(actor)
	local reason: string = ActionUtils.expectRejected(actions:RequestAction("Action.Cast"))
	expect(reason).toBe("ActionResourcePlanningFailed:InsufficientResourceValue:Resource.Mana")
	expect(resources:GetCurrent("Resource.Mana")).toBe(40)
	expect(resources:GetCurrent("Resource.Stamina")).toBe(20)
	expect(publication:GetActorSequence(actor)).toBe(0)
	expect(publication:CaptureBaseline(actor)).toEqual(before)
end)
