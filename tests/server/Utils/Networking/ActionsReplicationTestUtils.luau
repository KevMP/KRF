--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local expect: any = JestGlobals.expect
local ActionTypes = require(KRF.server.Action.types)
local ActorTypes = require(KRF.server.Actor.types)
local ResourceTypes = require(KRF.server.Resource.types)
local TagTypes = require(KRF.server.Tags.types)
local ReplicationTypes = require(KRF.server.Replication.types)
local NetworkingTypes = require(KRF.server.Networking.types)
local Domains: ReplicationTypes.ReplicationDomainRegistry = require(KRF.server.Replication.ReplicationDomainRegistry)
local Networking: NetworkingTypes.ServerNetworking = require(KRF.server.Networking.ServerNetworking)
local ActionUtils = require(script.Parent.Parent.Action.ActionResourceTestUtils)
local Builder = require(KRF.server.Replication.BuiltInReplicationDomains)
local ActionRegistry: ActionTypes.ActionRegistry = require(KRF.server.Action.ActionRegistry)

export type Identity = ActionTypes.ActionReplicationIdentity
export type Mutation = ActionTypes.ActionReplicationMutation
export type InternalController = ActionTypes.InternalActionController

local TestUtils = {}

function TestUtils.build(): ReplicationTypes.ReplicationDomainDefinition
	local definitions: { ReplicationTypes.ReplicationDomainDefinition }?, reason: string? = Builder.Build({
		tags = {},
		resources = {},
		actions = ActionRegistry.GetAll(),
	})

	expect(reason).toBeNil()
	assert(definitions ~= nil, reason)

	for _, definition: ReplicationTypes.ReplicationDomainDefinition in definitions do
		if definition.id == "KRF.Actions" then
			return definition
		end
	end

	expect(#definitions).toBe(1)
	error("N8 must build the visible Actions projection", 0)
end

function TestUtils.action(id: string, visibility: ActionTypes.ActionVisibility?): ActionTypes.ActionDefinition
	return { id = id, visibility = visibility or "ClientVisible", autoGrant = true }
end

function TestUtils.initialize(definitions: { ActionTypes.ActionDefinition }): ()
	ActionUtils.initialize(definitions, {
		{ id = "Mana", visibility = "ClientVisible", autoAssign = true, initialValue = 100, max = { value = 100 } },
	}, {
		{ id = "OwnerA", visibility = "ClientVisible", duplicateBehavior = "Ignore" },
		{ id = "OwnerB", visibility = "ClientVisible", duplicateBehavior = "Ignore" },
		{ id = "Incoming", visibility = "ClientVisible", duplicateBehavior = "Ignore" },
		{ id = "Applied", visibility = "ClientVisible", duplicateBehavior = "Ignore" },
	})
end

function TestUtils.internal(controller: ActionTypes.ActionController): InternalController
	local candidate: InternalController = controller :: InternalController
	expect(type(candidate._observeMutations)).toBe("function")
	expect(type(candidate._getActiveReplicationState)).toBe("function")

	return candidate
end

function TestUtils.domain(): ReplicationTypes.LoadedReplicationDomainDefinition
	local domain: ReplicationTypes.LoadedReplicationDomainDefinition? = Domains.Get("KRF.Actions")
	expect(domain).never.toBeNil()
	assert(domain ~= nil, "N8 must register KRF.Actions for a visible catalog")

	return domain
end

function TestUtils.publication(): NetworkingTypes.PublicationRuntime
	local runtime: NetworkingTypes.PublicationRuntime? = Networking._GetPublicationRuntimeForTests()
	assert(runtime ~= nil, "Normal Server.Init must install N3")

	return runtime
end

function TestUtils.accept(controller: ActionTypes.ActionController, id: string, parameters: any?): number
	local result: ActionTypes.ActionRequestResult = controller:RequestAction(id, parameters)
	expect(result.accepted).toBe(true)
	assert(result.accepted, "Expected accepted setup Action")

	return result.sequenceId
end

function TestUtils.state(actor: ActorTypes.Actor): { [number]: string }
	local baseline: NetworkingTypes.PublicationBaseline? = TestUtils.publication():CaptureBaseline(actor)
	assert(baseline ~= nil, "Expected admitted Actor baseline")
	local domain: NetworkingTypes.PublicationDomainTruth? = baseline.domains["KRF.Actions"]
	expect(domain).never.toBeNil()
	assert(domain ~= nil, "N8 baseline must contain visible Actions")

	return domain.value
end

function TestUtils.observe(): { NetworkingTypes.PublicationCommit }
	local commits: { NetworkingTypes.PublicationCommit } = {}

	TestUtils.publication():ObserveCommits(function(commit: NetworkingTypes.PublicationCommit)
		table.insert(commits, commit)
	end)

	return commits
end

function TestUtils.events(commit: NetworkingTypes.PublicationCommit): { NetworkingTypes.PublicationEvent }
	local events: { NetworkingTypes.PublicationEvent } = {}

	for _, event: NetworkingTypes.PublicationEvent in commit.events do
		if event.domainId == "KRF.Actions" then
			table.insert(events, event)
		end
	end

	return events
end

function TestUtils.controllers(actor: ActorTypes.Actor): (ResourceTypes.ResourceController, TagTypes.TagController)
	return actor:GetController("ResourceController") :: ResourceTypes.ResourceController,
		actor:GetController("TagController") :: TagTypes.TagController
end

return TestUtils
