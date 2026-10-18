--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local expect: any = JestGlobals.expect
local ActorTypes = require(KRF.server.Actor.types)
local TagTypes = require(KRF.server.Tags.types)
local ReplicationTypes = require(KRF.server.Replication.types)
local ActorEntity = require(KRF.server.Actor.ActorEntity)
local TagController = require(KRF.server.Tags.TagController)
local TagRegistry: TagTypes.TagRegistry = require(KRF.server.Tags.TagRegistry)
local Adapter = require(KRF.server.Networking.utils.TagsReplication)

export type Commit = { events: { ReplicationTypes.ReplicationDomainEvent }, state: Adapter.ReplicatedTagsState }

export type Fixture = {
	actor: ActorTypes.Actor,
	tags: TagTypes.InternalTagController,
	definition: ReplicationTypes.ReplicationDomainDefinition,
	clock: { now: number, reads: number },
	commits: { Commit },
	disconnects: { () -> () },
}

local TestUtils = {}

function TestUtils.catalog(): { TagTypes.TagDefinition }
	return {
		{ id = "Status.Burning", visibility = "ClientVisible", duplicateBehavior = "Refresh", defaultDuration = 10 },
		{ id = "Buff.Stack", visibility = "ClientVisible", duplicateBehavior = "Stack", maxStacks = 3 },
		{ id = "Status.Permanent", visibility = "ClientVisible", duplicateBehavior = "Ignore" },
		{ id = "Private.Refresh", visibility = "ServerOnly", duplicateBehavior = "Refresh", defaultDuration = 4 },
		{ id = "Private.Stack", visibility = "ServerOnly", duplicateBehavior = "Stack", maxStacks = 2 },
	}
end

function TestUtils.add(fixture: Fixture, tagId: string, duration: number?): ()
	local success: boolean, reason: string? =
		fixture.tags:AddTag(tagId, if duration ~= nil then { duration = duration } else nil)

	expect(reason).toBeNil()
	expect(success).toBe(true)
end

function TestUtils.new(catalog: { TagTypes.TagDefinition }?): Fixture
	TagController._setAutomaticSteppingEnabledForTests(false)
	TagRegistry._resetForTests()
	local definitions: { TagTypes.TagDefinition } = catalog or TestUtils.catalog()
	local loaded: boolean, reason: string? = TagRegistry.Load(definitions)
	assert(loaded, reason)
	local clock = { now = 1000, reads = 0 }

	local definition: ReplicationTypes.ReplicationDomainDefinition? = Adapter.Build(definitions, function(): number
		clock.reads += 1

		return clock.now
	end)

	assert(definition ~= nil, "Fixture requires a catalog with visible Tags")

	local actor: ActorTypes.Actor = ActorEntity.new()
	actor.enabled = true

	local tags: TagTypes.InternalTagController = TagController.new(actor) :: TagTypes.InternalTagController
	assert(actor:SetController("TagController", tags), "Expected built-in controller installation")

	return { actor = actor, tags = tags, definition = definition, clock = clock, commits = {}, disconnects = {} }
end

function TestUtils.snapshot(fixture: Fixture): Adapter.ReplicatedTagsState
	return fixture.definition.snapshot(fixture.actor)
end

function TestUtils.observe(fixture: Fixture): () -> ()
	-- N3 captures before observing. Keep that ordering in this adapter harness.
	TestUtils.snapshot(fixture)
	local observe = fixture.definition.observe
	assert(observe ~= nil, "Declared adapter must support observation")

	local disconnect: (() -> ())? = observe(
		fixture.actor,
		function(events: { ReplicationTypes.ReplicationDomainEvent }?): ()
			local snapshot: Adapter.ReplicatedTagsState = TestUtils.snapshot(fixture)
			local owned: Adapter.ReplicatedTagsState = {}

			for id: string, entry: Adapter.ReplicatedTagState in snapshot do
				owned[id] = table.clone(entry)
			end

			local committedEvents: { ReplicationTypes.ReplicationDomainEvent } = events or {}
			local commit: Commit = { events = table.clone(committedEvents), state = owned }
			table.insert(fixture.commits, commit)
		end
	)

	assert(disconnect ~= nil, "Adapter observation must return cleanup")
	table.insert(fixture.disconnects, disconnect)

	return disconnect
end

function TestUtils.step(fixture: Fixture, seconds: number): ()
	fixture.clock.now += seconds
	TagController.Step(seconds)
end

function TestUtils.destroy(fixture: Fixture): ()
	for _, disconnect in fixture.disconnects do
		disconnect()
	end

	fixture.tags:Destroy()
	TagRegistry._resetForTests()
	TagController._setAutomaticSteppingEnabledForTests(true)
end

return TestUtils
