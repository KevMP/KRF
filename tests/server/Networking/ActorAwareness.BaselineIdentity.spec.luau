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

it("establishes identity once and delivers subsequent replacement work by handle only", function()
	local player: Player = TestUtils.player(fixture)
	local actor: ActorTypes.Actor = TestUtils.actor(fixture, nil)
	local runtime: ServerNetworkingTypes.ActorAwarenessRuntime = TestUtils.start(fixture)
	TestUtils.ready(fixture, player)
	TestUtils.drain(fixture)
	local initial: any = TestUtils.kind(fixture, player, "BaselineBegin")[1]
	expect(initial.actorId).toBe(actor:GetId())
	fixture.deliveries = {}
	fixture.publicDomain.value = 14
	fixture.publicDomain.callbacks[actor]()
	expect(runtime:RequestReplacementBaseline(player, initial.handle, nil)).toBe(true)
	TestUtils.drain(fixture)
	local replacements: { any } = TestUtils.kind(fixture, player, "BaselineBegin")
	expect(#replacements).toBe(1)
	expect(replacements[1].handle).toBe(initial.handle)
	expect(replacements[1].actorId).toBeNil()
	expect(replacements[1].generation > initial.generation).toBe(true)
	expect(TestUtils.baseline(fixture, player, initial.handle)).toEqual({ ["Game.Public"] = { value = 14 } })
	for _, delivery: TestUtils.Delivery in fixture.deliveries do
		expect(string.find(buffer.tostring(delivery.payload), actor:GetId(), 1, true)).toBeNil()
	end
end)

it("omits identity when recapturing after an initial Begin was already sent", function()
	fixture.options.maxChunkBytes = 1
	fixture.options.maxEvents = 1
	local player: Player = TestUtils.player(fixture)
	local actor: ActorTypes.Actor = TestUtils.actor(fixture, nil)
	local runtime: ServerNetworkingTypes.ActorAwarenessRuntime = TestUtils.start(fixture)
	TestUtils.ready(fixture, player)
	runtime:Step(256, 1)
	local initial: any = TestUtils.kind(fixture, player, "BaselineBegin")[1]
	expect(initial.actorId).toBe(actor:GetId())
	fixture.deliveries = {}
	for value: number = 11, 14 do
		fixture.publicDomain.value = value
		fixture.publicDomain.callbacks[actor]({ { id = "Changed", payload = value } })
	end
	TestUtils.drain(fixture)
	local begins: { any } = TestUtils.kind(fixture, player, "BaselineBegin")
	expect(#begins >= 1).toBe(true)
	for _, begin: any in begins do
		expect(begin.handle).toBe(initial.handle)
		expect(begin.actorId).toBeNil()
	end
	expect(TestUtils.baseline(fixture, player, initial.handle)).toEqual({ ["Game.Public"] = { value = 14 } })
end)

it("retains identity when recapture replaces work before any initial Begin was sent", function()
	fixture.options.maxEvents = 1
	local player: Player = TestUtils.player(fixture)
	local actor: ActorTypes.Actor = TestUtils.actor(fixture, nil)
	local runtime: ServerNetworkingTypes.ActorAwarenessRuntime = TestUtils.start(fixture)
	TestUtils.ready(fixture, player)
	for value: number = 11, 14 do
		fixture.publicDomain.value = value
		fixture.publicDomain.callbacks[actor]({ { id = "Changed", payload = value } })
	end
	expect(fixture.deliveries).toEqual({})
	TestUtils.drain(fixture)
	local begins: { any } = TestUtils.kind(fixture, player, "BaselineBegin")
	expect(#begins).toBe(1)
	expect(begins[1].actorId).toBe(actor:GetId())
	expect(begins[1].handle).toBe(runtime:GetHandle(player, actor))
end)
