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

beforeEach(function()
	fixture = TestUtils.new()
end)

afterEach(function()
	TestUtils.destroy(fixture)
end)

it("sends no Actor work to a connection that has not become Ready", function()
	local player: Player = TestUtils.player(fixture)
	local actor: ActorTypes.Actor = TestUtils.actor(fixture, nil)
	local runtime: ServerNetworkingTypes.ActorAwarenessRuntime = TestUtils.start(fixture)
	TestUtils.drain(fixture)
	expect(runtime:IsAware(player, actor)).toBe(false)
	expect(runtime:GetHandle(player, actor)).toBeNil()
	expect(fixture.deliveries).toEqual({})
end)

it("subscribes to private Ready and Closed lifecycle and releases both subscriptions on destroy", function()
	local runtime: ServerNetworkingTypes.ActorAwarenessRuntime = TestUtils.start(fixture)
	expect(#fixture.readyObservers).toBe(1)
	expect(#fixture.closedObservers).toBe(1)
	runtime:Destroy()
	fixture.runtime = nil
	expect(fixture.readyObservers).toEqual({})
	expect(fixture.closedObservers).toEqual({})
end)

it("accepts Ready with zero Actors without sending baseline work", function()
	TestUtils.start(fixture)
	TestUtils.ready(fixture, TestUtils.player(fixture))
	TestUtils.drain(fixture)
	expect(fixture.deliveries).toEqual({})
	expect(fixture.faults).toEqual({})
end)

it("creates exactly one baseline for each existing N3 attached Actor", function()
	local player: Player = TestUtils.player(fixture)
	local first: ActorTypes.Actor = TestUtils.actor(fixture, nil)
	local second: ActorTypes.Actor = TestUtils.actor(fixture, nil)
	local runtime: ServerNetworkingTypes.ActorAwarenessRuntime = TestUtils.start(fixture)
	TestUtils.ready(fixture, player)
	TestUtils.drain(fixture)
	expect(runtime:IsAware(player, first)).toBe(true)
	expect(runtime:IsAware(player, second)).toBe(true)
	local ids: { string } = {}

	for _, record: any in TestUtils.kind(fixture, player, "BaselineBegin") do
		table.insert(ids, record.actorId)
	end

	table.sort(ids)
	local expectedIds: { string } = { first:GetId(), second:GetId() }
	table.sort(expectedIds)
	expect(ids).toEqual(expectedIds)
	expect(#TestUtils.kind(fixture, player, "BaselineEnd")).toBe(2)
end)

it("creates awareness synchronously for an Actor registered after Ready", function()
	local runtime: ServerNetworkingTypes.ActorAwarenessRuntime = TestUtils.start(fixture)
	local player: Player = TestUtils.player(fixture)
	TestUtils.ready(fixture, player)
	local actor: ActorTypes.Actor = TestUtils.actor(fixture, nil)
	expect(runtime:IsAware(player, actor)).toBe(true)
	TestUtils.drain(fixture)
	expect(#TestUtils.kind(fixture, player, "BaselineBegin")).toBe(1)
end)

it("deduplicates repeated Ready and registration notifications for the same stream", function()
	local runtime: ServerNetworkingTypes.ActorAwarenessRuntime = TestUtils.start(fixture)
	local actor: ActorTypes.Actor = TestUtils.actor(fixture, nil)
	local player: Player = TestUtils.player(fixture)
	TestUtils.ready(fixture, player)
	local handle: number? = runtime:GetHandle(player, actor)
	TestUtils.ready(fixture, player)
	runtime:OnActorRegistered(actor)
	TestUtils.drain(fixture)
	expect(runtime:GetHandle(player, actor)).toBe(handle)
	expect(#TestUtils.kind(fixture, player, "BaselineBegin")).toBe(1)
end)

it("drops all streams on close without sending removal traffic or affecting another recipient", function()
	local actor: ActorTypes.Actor = TestUtils.actor(fixture, nil)
	local runtime: ServerNetworkingTypes.ActorAwarenessRuntime = TestUtils.start(fixture)
	local departed: Player = TestUtils.player(fixture)
	local remaining: Player = TestUtils.player(fixture)
	TestUtils.ready(fixture, departed)
	TestUtils.ready(fixture, remaining)
	TestUtils.close(fixture, departed)
	TestUtils.drain(fixture)
	expect(runtime:IsAware(departed, actor)).toBe(false)
	expect(runtime:GetHandle(departed, actor)).toBeNil()
	expect(TestUtils.records(fixture, departed)).toEqual({})
	expect(runtime:IsAware(remaining, actor)).toBe(true)
	expect(#TestUtils.kind(fixture, remaining, "BaselineEnd")).toBe(1)
end)

it("does not enumerate attached Actors again during idle scheduler passes", function()
	TestUtils.actor(fixture, nil)
	local original: typeof(fixture.publication.GetAttachedActors) = fixture.publication.GetAttachedActors
	local calls: number = 0

	fixture.publication.GetAttachedActors = function(self): { ActorTypes.Actor }
		calls += 1

		return original(self)
	end

	TestUtils.start(fixture)
	TestUtils.ready(fixture, TestUtils.player(fixture))
	local initializationCalls: number = calls
	expect(initializationCalls > 0).toBe(true)
	TestUtils.drain(fixture)
	expect(calls).toBe(initializationCalls)
end)

it("touches only current Ready recipients when a new Actor registers after another connection closes", function()
	local departed: Player = TestUtils.player(fixture)
	local remaining: Player = TestUtils.player(fixture)
	local checked: { Player } = {}
	local original: typeof(fixture.dependencies.IsClientReady) = fixture.dependencies.IsClientReady

	fixture.dependencies.IsClientReady = function(player: Player): boolean
		table.insert(checked, player)

		return original(player)
	end

	local runtime: ServerNetworkingTypes.ActorAwarenessRuntime = TestUtils.start(fixture)
	TestUtils.ready(fixture, departed)
	TestUtils.ready(fixture, remaining)
	TestUtils.close(fixture, departed)
	checked = {}
	local actor: ActorTypes.Actor = TestUtils.actor(fixture, nil)
	TestUtils.drain(fixture)
	expect(table.find(checked, departed)).toBeNil()
	expect(TestUtils.records(fixture, departed)).toEqual({})
	expect(runtime:GetHandle(departed, actor)).toBeNil()
	expect(runtime:IsAware(remaining, actor)).toBe(true)
	expect(#TestUtils.kind(fixture, remaining, "BaselineBegin")).toBe(1)
	expect(#TestUtils.kind(fixture, remaining, "BaselineEnd")).toBe(1)
end)
