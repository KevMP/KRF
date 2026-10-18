--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local ServerNetworkingTypes = require(KRF.server.Networking.types)
local ActorTypes = require(KRF.server.Actor.types)
local SharedNetworkingTypes = require(KRF.shared.Networking.types)
local Constants = require(KRF.shared.Networking.utils.ActorProtocolConstants)
local TestUtils = require(script.Parent.Parent.Utils.Networking.AwarenessTestUtils)

local fixture: TestUtils.Fixture
beforeEach(function()
	fixture = TestUtils.new()
end)
afterEach(function()
	TestUtils.destroy(fixture)
end)

it("batches different Actors' baseline and live records while preserving each stream's order", function()
	local player: Player = TestUtils.player(fixture)
	local first: ActorTypes.Actor = TestUtils.actor(fixture, nil)
	local second: ActorTypes.Actor = TestUtils.actor(fixture, nil)
	local runtime: ServerNetworkingTypes.ActorAwarenessRuntime = TestUtils.start(fixture)
	TestUtils.ready(fixture, player)
	runtime:Step(512, 8)
	expect(#fixture.deliveries).toBe(1)
	expect(#TestUtils.kind(fixture, player, "BaselineBegin")).toBe(2)
	TestUtils.drain(fixture)
	expect(#TestUtils.kind(fixture, player, "BaselineEnd")).toBe(2)
	fixture.deliveries = {}
	fixture.publicDomain.value = 12
	fixture.publicDomain.callbacks[first]()
	fixture.publicDomain.callbacks[second]()
	runtime:Step(512, 8)
	expect(#fixture.deliveries).toBe(1)
	local records: { SharedNetworkingTypes.ActorStreamRecord } = TestUtils.records(fixture, player)
	expect(#records).toBe(2)
	for _, record: SharedNetworkingTypes.ActorStreamRecord in records do
		expect(record.kind).toBe("Commit")
		assert(record.kind == "Commit", "Expected live record")
		expect(record.revision).toBe(2)
	end
end)

it("completes a large join within packet and concurrent baseline limits", function()
	local player: Player = TestUtils.player(fixture)
	local actors: { ActorTypes.Actor } = {}
	for _ = 1, 1200 do
		table.insert(actors, TestUtils.actor(fixture, nil))
	end
	local runtime: ServerNetworkingTypes.ActorAwarenessRuntime = TestUtils.start(fixture)
	TestUtils.ready(fixture, player)
	runtime:Step(Constants.MAX_PACKET_BYTES * 2, 1200)
	expect(#TestUtils.kind(fixture, player, "BaselineBegin")).toBe(Constants.MAX_PENDING_BASELINES)
	for _ = 1, 300 do
		runtime:Step(Constants.MAX_PACKET_BYTES * 2, 1200)
	end
	expect(#TestUtils.kind(fixture, player, "BaselineEnd")).toBe(1200)
	for _, delivery: TestUtils.Delivery in fixture.deliveries do
		expect(buffer.len(delivery.payload) <= Constants.MAX_PACKET_BYTES).toBe(true)
	end
	fixture.deliveries = {}
	fixture.publicDomain.value = 11
	for _, actor: ActorTypes.Actor in actors do
		fixture.publicDomain.callbacks[actor]({
			{ id = "Changed", payload = 1 },
			{ id = "Changed", payload = 2 },
			{ id = "Changed", payload = 3 },
			{ id = "Changed", payload = 4 },
		})
	end
	runtime:Step(Constants.MAX_PACKET_BYTES * 2, 1200)
	expect(#fixture.deliveries > 1).toBe(true)
	expect(#TestUtils.kind(fixture, player, "Commit")).toBe(1200)
	for _, delivery: TestUtils.Delivery in fixture.deliveries do
		expect(buffer.len(delivery.payload) <= Constants.MAX_PACKET_BYTES).toBe(true)
	end
end)

it("drops a staged recipient packet if that connection closes during another Reliable send", function()
	local first: Player = TestUtils.player(fixture)
	local departed: Player = TestUtils.player(fixture)
	TestUtils.actor(fixture, nil)
	local runtime: ServerNetworkingTypes.ActorAwarenessRuntime = TestUtils.start(fixture)
	TestUtils.ready(fixture, first)
	TestUtils.ready(fixture, departed)
	fixture.dependencies.SendReliable = function(player: Player, payload: buffer): (boolean, string?)
		table.insert(fixture.deliveries, { player = player, payload = payload })
		if player == first then
			TestUtils.close(fixture, departed)
		end
		return true, nil
	end
	runtime:Step(512, 2)
	expect(TestUtils.records(fixture, departed)).toEqual({})
	TestUtils.drain(fixture)
	expect(#TestUtils.kind(fixture, first, "BaselineEnd")).toBe(1)
end)

it("does not retry a failed removal or repeatedly report an already halted stream", function()
	local player: Player = TestUtils.player(fixture)
	local actor: ActorTypes.Actor = TestUtils.actor(fixture, nil)
	local runtime: ServerNetworkingTypes.ActorAwarenessRuntime = TestUtils.start(fixture)
	local attempts: number = 0
	fixture.dependencies.SendReliable = function(_player: Player, _payload: buffer): (boolean, string?)
		attempts += 1
		return false, "ForcedSendFailure"
	end
	TestUtils.ready(fixture, player)
	TestUtils.drain(fixture)
	runtime:OnActorUnregistering(actor)
	TestUtils.drain(fixture)
	expect(attempts).toBe(2)
	expect(#fixture.faults).toBe(1)
	expect(runtime:IsAware(player, actor)).toBe(false)
end)

for _, boundary: string in { "BaselineBegin", "BaselineChunk", "BaselineEnd" } do
	it("preserves a replacement requested reentrantly during delivery of " .. boundary, function()
		local player: Player = TestUtils.player(fixture)
		local actor: ActorTypes.Actor = TestUtils.actor(fixture, player)
		local runtime: ServerNetworkingTypes.ActorAwarenessRuntime = TestUtils.start(fixture)
		local changed: boolean = false
		fixture.dependencies.SendReliable = function(recipient: Player, payload: buffer): (boolean, string?)
			table.insert(fixture.deliveries, { player = recipient, payload = payload })
			local records: { SharedNetworkingTypes.ActorStreamRecord }?, reason: string? = fixture.codec.Decode(payload)
			assert(records ~= nil, reason)
			if not changed and records[1].kind == boundary then
				changed = true
				TestUtils.associate(fixture, actor, nil)
			end
			return true, nil
		end
		TestUtils.ready(fixture, player)
		TestUtils.drain(fixture)
		local handle: number? = runtime:GetHandle(player, actor)
		assert(handle ~= nil, "Expected stable stream handle")
		expect(changed).toBe(true)
		expect(TestUtils.baseline(fixture, player, handle)).toEqual({ ["Game.Public"] = { value = 10 } })
		local begins: { any } = TestUtils.kind(fixture, player, "BaselineBegin")
		expect(#begins).toBe(2)
		expect(begins[2].actorId).toBeNil()
		expect(begins[2].generation > begins[1].generation).toBe(true)
	end)
end
