--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local ActorTypes = require(KRF.server.Actor.types)
local NetworkingTypes = require(KRF.server.Networking.types)
local TestUtils = require(script.Parent.Parent.Utils.Networking.AwarenessTestUtils)

local fixture: TestUtils.Fixture

beforeEach(function()
	fixture = TestUtils.new()
end)

afterEach(function()
	TestUtils.destroy(fixture)
end)

local function handle(runtime: NetworkingTypes.ActorAwarenessRuntime, player: Player, actor: ActorTypes.Actor): number
	local assigned: number? = runtime:GetHandle(player, actor)
	assert(assigned ~= nil, "Fixture must have an actual N4 handle")

	return assigned
end

local function expectUnavailable(runtime: NetworkingTypes.ActorAwarenessRuntime, player: Player, target: number): ()
	local actor: ActorTypes.Actor?, reason: string? = runtime:ResolveActor(player, target)
	expect(actor).toBeNil()
	expect(type(reason)).toBe("string")
end

it("resolves the private connection-local handle to the exact authoritative Actor", function()
	local runtime: NetworkingTypes.ActorAwarenessRuntime = TestUtils.start(fixture)
	local player: Player = TestUtils.player(fixture)
	TestUtils.ready(fixture, player)
	local actor: ActorTypes.Actor = TestUtils.actor(fixture, player)
	TestUtils.drain(fixture)
	local resolved: ActorTypes.Actor?, reason: string? = runtime:ResolveActor(player, handle(runtime, player, actor))
	expect(reason).toBeNil()
	expect(resolved).toBe(actor)
	expect(runtime:GetActorForPlayer(player)).toBe(actor)
end)

it("does not import a handle from another Ready connection's different allocation history", function()
	local runtime: NetworkingTypes.ActorAwarenessRuntime = TestUtils.start(fixture)
	local first: Player = TestUtils.player(fixture)
	TestUtils.ready(fixture, first)
	local removed: ActorTypes.Actor = TestUtils.actor(fixture)
	runtime:OnActorUnregistering(removed)
	fixture.publication:DetachActor(removed)
	local live: ActorTypes.Actor = TestUtils.actor(fixture)
	local firstHandle: number = handle(runtime, first, live)
	local second: Player = TestUtils.player(fixture)
	TestUtils.ready(fixture, second)
	TestUtils.drain(fixture)
	expect(handle(runtime, second, live)).never.toBe(firstHandle)
	expectUnavailable(runtime, second, firstHandle)
	local resolved: ActorTypes.Actor?, reason: string? = runtime:ResolveActor(first, firstHandle)
	expect(reason).toBeNil()
	expect(resolved).toBe(live)
end)

it(
	"retires targets immediately on unregister before queued ActorRemove delivery and never aliases a respawn",
	function()
		local runtime: NetworkingTypes.ActorAwarenessRuntime = TestUtils.start(fixture)
		local player: Player = TestUtils.player(fixture)
		TestUtils.ready(fixture, player)
		local actor: ActorTypes.Actor = TestUtils.actor(fixture)
		TestUtils.drain(fixture)
		local retired: number = handle(runtime, player, actor)
		runtime:OnActorUnregistering(actor)
		expectUnavailable(runtime, player, retired)
		fixture.publication:DetachActor(actor)
		local respawn: ActorTypes.Actor = TestUtils.actor(fixture)
		TestUtils.drain(fixture)
		expect(handle(runtime, player, respawn)).never.toBe(retired)
		expectUnavailable(runtime, player, retired)
	end
)

for _, invalid: number in { 0, -1, 1.5, 4294967296, math.huge } do
	it("rejects malformed handle " .. tostring(invalid) .. " without manufacturing an Actor", function()
		local runtime: NetworkingTypes.ActorAwarenessRuntime = TestUtils.start(fixture)
		local player: Player = TestUtils.player(fixture)
		TestUtils.ready(fixture, player)
		TestUtils.actor(fixture)
		expectUnavailable(runtime, player, invalid)
	end)
end

for _, state: string in { "Unknown", "NonReady", "Closed", "Detached", "Disabled", "Halted", "MissingForwardMap" } do
	it("rejects " .. state .. " targets despite any retained handle entry", function()
		local runtime: NetworkingTypes.ActorAwarenessRuntime = TestUtils.start(fixture)
		local player: Player = TestUtils.player(fixture)
		TestUtils.ready(fixture, player)
		local actor: ActorTypes.Actor = TestUtils.actor(fixture)
		TestUtils.drain(fixture)
		local target: number = handle(runtime, player, actor)

		if state == "Unknown" then
			target += 100
		elseif state == "NonReady" then
			fixture.readyPlayers[player] = nil
		elseif state == "Closed" then
			TestUtils.close(fixture, player)
		elseif state == "Detached" then
			fixture.publication:DetachActor(actor)
		elseif state == "Disabled" then
			actor.enabled = false
		elseif state == "MissingForwardMap" then
			local connections: any = (runtime :: any).connections
			connections[player].actors[actor] = nil
		else
			fixture.dependencies.SendReliable = function(): (boolean, string?)
				return false, "ForcedCommandTargetStreamHalt"
			end

			fixture.publicDomain.value = 11
			fixture.publicDomain.callbacks[actor]()
			TestUtils.drain(fixture)
			expect(#fixture.faults).toBe(1)
		end

		expectUnavailable(runtime, player, target)
	end)
end
