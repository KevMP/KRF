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
local SharedNetworkingTypes = require(KRF.shared.Networking.types)
local TestUtils = require(script.Parent.Parent.Utils.Networking.AwarenessTestUtils)

local fixture: TestUtils.Fixture

beforeEach(function()
	fixture = TestUtils.new()
end)

afterEach(function()
	TestUtils.destroy(fixture)
end)

it("sizes one immutable public commit once across ten recipients and reuses its charge during scheduling", function()
	local actor: ActorTypes.Actor = TestUtils.actor(fixture, nil)
	local runtime: ServerNetworkingTypes.ActorAwarenessRuntime = TestUtils.start(fixture)
	local players: { Player } = {}

	for _ = 1, 10 do
		local player: Player = TestUtils.player(fixture)
		table.insert(players, player)
		TestUtils.ready(fixture, player)
	end

	TestUtils.drain(fixture)
	fixture.deliveries = {}

	local codec: SharedNetworkingTypes.ActorStreamCodec = (runtime :: any).codec
	local original = codec.Measure
	local calls: number = 0

	codec.Measure = function(records: { SharedNetworkingTypes.ActorStreamRecord }): (number?, string?)
		calls += 1

		return original(records)
	end

	fixture.publicDomain.value = 11
	fixture.publicDomain.callbacks[actor]({ { id = "Changed", payload = 11 } })
	expect(calls).toBe(1)
	TestUtils.drain(fixture)
	expect(calls).toBe(1)

	for _, player: Player in players do
		local commits: { any } = TestUtils.kind(fixture, player, "Commit")
		expect(#commits).toBe(1)
		expect(commits[1].patches).toEqual({ { domainId = "Game.Public", patch = { kind = "Replace", value = 11 } } })
		expect(commits[1].events).toEqual({ { domainId = "Game.Public", eventId = "Changed", payload = 11 } })
	end

	expect(fixture.faults).toEqual({})
end)

it("sizes Owner and public projections separately without exposing hidden state", function()
	local owner: Player = TestUtils.player(fixture)
	local actor: ActorTypes.Actor = TestUtils.actor(fixture, owner)
	local runtime: ServerNetworkingTypes.ActorAwarenessRuntime = TestUtils.start(fixture)
	TestUtils.ready(fixture, owner)
	local observers: { Player } = {}

	for _ = 1, 9 do
		local player: Player = TestUtils.player(fixture)
		table.insert(observers, player)
		TestUtils.ready(fixture, player)
	end

	TestUtils.drain(fixture)
	fixture.deliveries = {}

	local codec: SharedNetworkingTypes.ActorStreamCodec = (runtime :: any).codec
	local original = codec.Measure
	local calls: number = 0

	codec.Measure = function(records: { SharedNetworkingTypes.ActorStreamRecord }): (number?, string?)
		calls += 1

		return original(records)
	end

	fixture.publication:WithActorCommit(actor, function()
		fixture.publicDomain.value = 11
		fixture.ownerDomain.value = 21
		fixture.publicDomain.callbacks[actor]({ { id = "Changed", payload = 11 } })
		fixture.ownerDomain.callbacks[actor]({ { id = "Changed", payload = 21 } })
	end)

	expect(calls).toBe(2)
	TestUtils.drain(fixture)
	expect(calls).toBe(2)
	expect(#TestUtils.kind(fixture, owner, "Commit")[1].patches).toBe(2)

	for _, player: Player in observers do
		local commits: { any } = TestUtils.kind(fixture, player, "Commit")
		expect(#commits).toBe(1)
		expect(commits[1].patches).toEqual({ { domainId = "Game.Public", patch = { kind = "Replace", value = 11 } } })
		expect(commits[1].events).toEqual({ { domainId = "Game.Public", eventId = "Changed", payload = 11 } })
	end
end)

it("remeasures recipient-specific compositions instead of reusing an earlier source commit charge", function()
	local actor: ActorTypes.Actor = TestUtils.actor(fixture, nil)
	local runtime: ServerNetworkingTypes.ActorAwarenessRuntime = TestUtils.start(fixture)
	local players: { Player } = {}

	for _ = 1, 10 do
		local player: Player = TestUtils.player(fixture)
		table.insert(players, player)
		TestUtils.ready(fixture, player)
	end

	TestUtils.drain(fixture)
	fixture.deliveries = {}

	local codec: SharedNetworkingTypes.ActorStreamCodec = (runtime :: any).codec
	local original = codec.Measure
	local calls: number = 0

	codec.Measure = function(records: { SharedNetworkingTypes.ActorStreamRecord }): (number?, string?)
		calls += 1

		return original(records)
	end

	fixture.publicDomain.value = 11
	fixture.publicDomain.callbacks[actor]()
	fixture.publicDomain.value = 12
	fixture.publicDomain.callbacks[actor]()
	expect(calls).toBe(11)
	TestUtils.drain(fixture)
	expect(calls).toBe(11)

	for _, player: Player in players do
		local commits: { any } = TestUtils.kind(fixture, player, "Commit")
		expect(#commits).toBe(1)
		expect(commits[1].events).toEqual({})
		expect(commits[1].patches).toEqual({ { domainId = "Game.Public", patch = { kind = "Replace", value = 12 } } })
	end
end)
