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

it("discards unsent initial baseline and queues exactly one reliable removal", function()
	local runtime: ServerNetworkingTypes.ActorAwarenessRuntime = TestUtils.start(fixture)
	local player: Player = TestUtils.player(fixture)
	TestUtils.ready(fixture, player)
	local actor: ActorTypes.Actor = TestUtils.actor(fixture, nil)
	local handle: number? = runtime:GetHandle(player, actor)
	runtime:OnActorUnregistering(actor)
	runtime:OnActorUnregistering(actor)
	fixture.publication:DetachActor(actor)
	TestUtils.drain(fixture)
	expect(TestUtils.records(fixture, player)).toEqual({ { kind = "ActorRemove", handle = handle } })
	expect(runtime:IsAware(player, actor)).toBe(false)
end)

it("preserves sent ordering but discards unsent live history and replacement on removal", function()
	local runtime: ServerNetworkingTypes.ActorAwarenessRuntime = TestUtils.start(fixture)
	local player: Player = TestUtils.player(fixture)
	TestUtils.ready(fixture, player)
	local actor: ActorTypes.Actor = TestUtils.actor(fixture, nil)
	TestUtils.drain(fixture)
	local sentCount: number = #TestUtils.records(fixture, player)
	local handle: number? = runtime:GetHandle(player, actor)
	assert(handle ~= nil, "Expected handle")
	fixture.publicDomain.value = 11
	fixture.publicDomain.callbacks[actor]({ { id = "Changed", payload = 11 } })
	expect(runtime:RequestReplacementBaseline(player, handle, nil)).toBe(true)
	runtime:OnActorUnregistering(actor)
	fixture.publication:DetachActor(actor)
	TestUtils.drain(fixture)
	local records: { any } = TestUtils.records(fixture, player)
	expect(#records).toBe(sentCount + 1)
	expect(records[#records]).toEqual({ kind = "ActorRemove", handle = handle })
	expect(TestUtils.kind(fixture, player, "Commit")).toEqual({})
	local success: boolean, reason: string? = runtime:RequestReplacementBaseline(player, handle, nil)
	expect(success).toBe(false)
	expect(reason).toBe("UnknownActorHandle")
end)

it("continues another Actor's queued publication when one Actor unregisters", function()
	local runtime: ServerNetworkingTypes.ActorAwarenessRuntime = TestUtils.start(fixture)
	local player: Player = TestUtils.player(fixture)
	TestUtils.ready(fixture, player)
	local removed: ActorTypes.Actor = TestUtils.actor(fixture, nil)
	local remaining: ActorTypes.Actor = TestUtils.actor(fixture, nil)
	TestUtils.drain(fixture)
	fixture.deliveries = {}
	fixture.publicDomain.value = 12
	fixture.publicDomain.callbacks[remaining]()
	runtime:OnActorUnregistering(removed)
	fixture.publication:DetachActor(removed)
	TestUtils.drain(fixture)
	expect(#TestUtils.kind(fixture, player, "ActorRemove")).toBe(1)
	local commits: { any } = TestUtils.kind(fixture, player, "Commit")
	expect(#commits).toBe(1)
	expect(commits[1].handle).toBe(runtime:GetHandle(player, remaining))
	expect(runtime:IsAware(player, remaining)).toBe(true)
end)

it("releases the N3 commit subscription and ignores retained producer callbacks after destroy", function()
	local runtime: ServerNetworkingTypes.ActorAwarenessRuntime = TestUtils.start(fixture)
	local player: Player = TestUtils.player(fixture)
	TestUtils.ready(fixture, player)
	local actor: ActorTypes.Actor = TestUtils.actor(fixture, nil)
	TestUtils.drain(fixture)
	fixture.deliveries = {}
	runtime:Destroy()
	runtime:Destroy()
	fixture.runtime = nil
	fixture.publicDomain.value = 12
	fixture.publicDomain.callbacks[actor]()
	runtime:Step(256, 8)
	expect(fixture.deliveries).toEqual({})
	expect(runtime:GetHandle(player, actor)).toBeNil()
	expect(fixture.readyObservers).toEqual({})
	expect(fixture.closedObservers).toEqual({})
end)
