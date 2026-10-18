--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF

local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local ActorTypes = require(KRF.server.Actor.types)
local ServerNetworkingTypes = require(KRF.server.Networking.types)
local TestUtils = require(script.Parent.Parent.Utils.Networking.AwarenessTestUtils)

local fixture: TestUtils.Fixture
local actor: ActorTypes.Actor
local owner: Player
local other: Player

beforeEach(function()
	fixture = TestUtils.new()
	owner = TestUtils.player(fixture)
	other = TestUtils.player(fixture)
	actor = TestUtils.actor(fixture, owner)
end)

afterEach(function()
	TestUtils.destroy(fixture)
end)

local function start(): ()
	TestUtils.start(fixture)
	TestUtils.ready(fixture, owner)
	TestUtils.ready(fixture, other)
	TestUtils.drain(fixture)
end

it("delivers public state and events to both aware recipients at the next baseline revision", function()
	start()
	local revision: number = TestUtils.kind(fixture, other, "BaselineEnd")[1].revision

	fixture.deliveries = {}
	fixture.publicDomain.value = 11
	fixture.publicDomain.callbacks[actor]({ { id = "Changed", payload = 11 } })
	TestUtils.drain(fixture)

	for _, player: Player in { owner, other } do
		local commits: { any } = TestUtils.kind(fixture, player, "Commit")
		expect(#commits).toBe(1)
		expect(commits[1].revision).toBe(revision + 1)
		expect(commits[1].patches).toEqual({ { domainId = "Game.Public", patch = { kind = "Replace", value = 11 } } })
		expect(commits[1].events).toEqual({ { domainId = "Game.Public", eventId = "Changed", payload = 11 } })
	end
end)

it("filters hidden Owner state and events before allocating a non-owner revision", function()
	start()
	local revision: number = TestUtils.kind(fixture, other, "BaselineEnd")[1].revision

	fixture.deliveries = {}
	fixture.ownerDomain.value = 21
	fixture.ownerDomain.callbacks[actor]({ { id = "Changed", payload = 21 } })
	TestUtils.drain(fixture)
	expect(TestUtils.records(fixture, other)).toEqual({})
	local private: { any } = TestUtils.kind(fixture, owner, "Commit")
	expect(#private).toBe(1)
	expect(private[1].patches).toEqual({ { domainId = "Game.Private", patch = { kind = "Replace", value = 21 } } })
	expect(private[1].events).toEqual({ { domainId = "Game.Private", eventId = "Changed", payload = 21 } })
	fixture.publicDomain.value = 12
	fixture.publicDomain.callbacks[actor]()
	TestUtils.drain(fixture)
	expect(TestUtils.kind(fixture, other, "Commit")[1].revision).toBe(revision + 1)
	expect(TestUtils.kind(fixture, owner, "Commit")[2].revision).toBe(revision + 2)
end)

it("preserves one mixed logical commit for owner and a public-only projection for non-owner", function()
	start()
	fixture.deliveries = {}

	fixture.publication:WithActorCommit(actor, function(): ()
		fixture.publicDomain.value = 11
		fixture.ownerDomain.value = 21
		fixture.publicDomain.callbacks[actor]({ { id = "Changed", payload = 11 } })
		fixture.ownerDomain.callbacks[actor]({ { id = "Changed", payload = 21 } })
	end)

	TestUtils.drain(fixture)
	local ownerRecords: { any } = TestUtils.kind(fixture, owner, "Commit")
	local publicRecords: { any } = TestUtils.kind(fixture, other, "Commit")
	expect(#ownerRecords).toBe(1)
	expect(#publicRecords).toBe(1)
	expect(#ownerRecords[1].patches).toBe(2)
	expect(#ownerRecords[1].events).toBe(2)
	expect(publicRecords[1].patches).toEqual({ { domainId = "Game.Public", patch = { kind = "Replace", value = 11 } } })
	expect(publicRecords[1].events).toEqual({ { domainId = "Game.Public", eventId = "Changed", payload = 11 } })
end)

it("assigns one revision after coalescing a burst of state-only source commits", function()
	start()
	local revision: number = TestUtils.kind(fixture, owner, "BaselineEnd")[1].revision

	fixture.deliveries = {}

	for value: number = 11, 100 do
		fixture.publicDomain.value = value
		fixture.publicDomain.callbacks[actor]()
	end

	TestUtils.drain(fixture)
	local records: { any } = TestUtils.kind(fixture, owner, "Commit")
	expect(#records).toBe(1)
	expect(records[1].revision).toBe(revision + 1)
	expect(records[1].patches).toEqual({ { domainId = "Game.Public", patch = { kind = "Replace", value = 100 } } })
end)

it("keeps required event barriers as distinct consecutive revisions", function()
	start()
	local revision: number = TestUtils.kind(fixture, owner, "BaselineEnd")[1].revision

	fixture.deliveries = {}
	fixture.publicDomain.callbacks[actor]({ { id = "Changed", payload = 1 } })
	fixture.publicDomain.callbacks[actor]({ { id = "Changed", payload = 2 } })
	TestUtils.drain(fixture)
	local records: { any } = TestUtils.kind(fixture, owner, "Commit")
	expect(#records).toBe(2)

	for index: number, record: any in records do
		expect(record.revision).toBe(revision + index)
		expect(record.events).toEqual({ { domainId = "Game.Public", eventId = "Changed", payload = index } })
	end
end)

it("permits public state coalescing when the only event barrier is hidden from that recipient", function()
	start()
	fixture.deliveries = {}

	fixture.publication:WithActorCommit(actor, function(): ()
		fixture.publicDomain.value = 11
		fixture.publicDomain.callbacks[actor]()
		fixture.ownerDomain.callbacks[actor]({ { id = "Changed", payload = 21 } })
	end)

	fixture.publicDomain.value = 12
	fixture.publicDomain.callbacks[actor]()
	TestUtils.drain(fixture)
	expect(#TestUtils.kind(fixture, owner, "Commit")).toBe(2)
	local records: { any } = TestUtils.kind(fixture, other, "Commit")
	expect(#records).toBe(1)
	expect(records[1].events).toEqual({})
	expect(records[1].patches).toEqual({ { domainId = "Game.Public", patch = { kind = "Replace", value = 12 } } })
end)

it("sends no Owner-only live work for an Actor without a Player association", function()
	start()
	local npc: ActorTypes.Actor = TestUtils.actor(fixture, nil)
	TestUtils.drain(fixture)
	fixture.deliveries = {}
	fixture.ownerDomain.value = 21
	fixture.ownerDomain.callbacks[npc]({ { id = "Changed", payload = 21 } })
	TestUtils.drain(fixture)
	expect(fixture.deliveries).toEqual({})
end)

it("never silently wraps a wire revision when its configured counter is exhausted", function()
	fixture.options.maxRevision = 2
	start()

	local previous: { [Player]: number } = {
		[owner] = TestUtils.kind(fixture, owner, "BaselineEnd")[1].revision,
		[other] = TestUtils.kind(fixture, other, "BaselineEnd")[1].revision,
	}

	fixture.deliveries = {}

	for value: number = 11, 15 do
		fixture.publicDomain.value = value
		fixture.publicDomain.callbacks[actor]()
		TestUtils.drain(fixture)
	end

	for _, player: Player in { owner, other } do
		for _, record: any in TestUtils.kind(fixture, player, "Commit") do
			expect(record.revision).toBe(previous[player] + 1)
			expect(record.revision <= fixture.options.maxRevision).toBe(true)
			previous[player] = record.revision
		end
	end

	expect(#fixture.faults >= 2).toBe(true)

	for _, fault: ServerNetworkingTypes.ActorAwarenessFault in fixture.faults do
		expect(fault.actorId).toBe(actor:GetId())
		expect(fault.reason).toBe("ActorRevisionExhausted")
	end
end)

it("does not mutate immutable N3 source patches or events while projecting recipients", function()
	start()
	local source: ServerNetworkingTypes.PublicationCommit? = nil

	fixture.publication:ObserveCommits(function(commit: ServerNetworkingTypes.PublicationCommit): ()
		source = commit
	end)

	fixture.publication:WithActorCommit(actor, function(): ()
		fixture.publicDomain.value = 11
		fixture.ownerDomain.value = 21
		fixture.publicDomain.callbacks[actor]({ { id = "Changed", payload = 11 } })
		fixture.ownerDomain.callbacks[actor]({ { id = "Changed", payload = 21 } })
	end)

	assert(source ~= nil, "Expected immutable authoritative commit")
	local patches: { ServerNetworkingTypes.PublicationDomainPatch } = source.patches
	local events: { ServerNetworkingTypes.PublicationEvent } = source.events
	TestUtils.drain(fixture)
	expect(source.patches).toBe(patches)
	expect(source.events).toBe(events)
	expect(#source.patches).toBe(2)
	expect(#source.events).toBe(2)
	expect(table.isfrozen(source)).toBe(true)
	expect(table.isfrozen(source.patches)).toBe(true)
	expect(#TestUtils.kind(fixture, other, "Commit")[1].patches).toBe(1)
	expect(#TestUtils.kind(fixture, owner, "Commit")[1].patches).toBe(2)
end)
