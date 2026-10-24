--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local Types = require(KRF.server.Networking.types)
local ActorTypes = require(KRF.server.Actor.types)
local Streams = require(KRF.server.Networking.utils.ActorRecipientStream)
local Constants = require(KRF.shared.Networking.utils.CommandConstants)
local SharedTypes = require(KRF.shared.Networking.types)
local TestUtils = require(script.Parent.Parent.Utils.Networking.AwarenessTestUtils)

local fixture: TestUtils.Fixture
local originalHasWork = Streams.HasWork
local originalHasWorkThrough = Streams.HasWorkThrough

beforeEach(function()
	fixture = TestUtils.new()
end)

it("detaches staged work when a send fault closes and readies the same Player", function()
	local player: Player = TestUtils.player(fixture)
	TestUtils.actor(fixture, nil)
	TestUtils.actor(fixture, nil)
	local runtime: Types.ActorAwarenessRuntime = TestUtils.start(fixture)
	local replaced = false

	fixture.dependencies.SendReliable = function(): (boolean, string?)
		return false, "InjectedSendFailure"
	end

	fixture.dependencies.ReportFault = function(): ()
		if not replaced then
			replaced = true

			for _, callback in fixture.closedObservers do
				callback(player)
			end

			TestUtils.ready(fixture, player)
		end
	end

	TestUtils.ready(fixture, player)
	runtime:Step(32768, 64)
	expect(replaced).toBe(true)

	fixture.dependencies.SendReliable = function(target: Player, payload: buffer): (boolean, string?)
		table.insert(fixture.deliveries, { player = target, payload = payload })

		return true, nil
	end

	TestUtils.drain(fixture)
	expect(#TestUtils.kind(fixture, player, "BaselineEnd")).toBe(2)
	expect(#TestUtils.kind(fixture, player, "ActorHalt")).toBe(0)
end)

it("does not close a replacement connection when an older result send returns failure", function()
	local player: Player = TestUtils.player(fixture)
	TestUtils.actor(fixture, nil)
	local runtime: Types.ActorAwarenessRuntime = TestUtils.start(fixture)
	TestUtils.ready(fixture, player)
	TestUtils.drain(fixture)
	fixture.deliveries = {}

	local reservation = assert(runtime:ReserveCommandResult(player, 1))
	expect(reservation.Commit(buffer.create(1))).toBe(true)

	fixture.dependencies.SendReliable = function(): (boolean, string?)
		for _, callback in fixture.closedObservers do
			callback(player)
		end

		TestUtils.ready(fixture, player)

		return false, "OldConnectionSendFailed"
	end

	runtime:Step(32768, 1)

	fixture.dependencies.SendReliable = function(target: Player, payload: buffer): (boolean, string?)
		table.insert(fixture.deliveries, { player = target, payload = payload })

		return true, nil
	end

	TestUtils.drain(fixture)
	expect(#TestUtils.kind(fixture, player, "BaselineEnd")).toBe(1)
end)

it("preserves a replacement connection when preparation reports a terminal stream fault", function()
	local player: Player = TestUtils.player(fixture)
	local healthy: ActorTypes.Actor = TestUtils.actor(fixture, nil)
	local actor: ActorTypes.Actor = TestUtils.actor(fixture, nil)
	local runtime: Types.ActorAwarenessRuntime = TestUtils.start(fixture)
	local replaced = false

	fixture.dependencies.ReportFault = function(): ()
		if not replaced then
			replaced = true

			for _, callback in fixture.closedObservers do
				callback(player)
			end

			TestUtils.ready(fixture, player)
		end
	end

	TestUtils.ready(fixture, player)
	TestUtils.drain(fixture)
	fixture.publicDomain.value = 11
	fixture.publicDomain.callbacks[actor]()
	TestUtils.drain(fixture)
	fixture.deliveries = {}
	fixture.options.maxRevision = 2
	fixture.publicDomain.value = 12
	fixture.publicDomain.callbacks[healthy]()
	fixture.publicDomain.value = 13
	fixture.publicDomain.callbacks[actor]()
	runtime:Step(32768, 64)
	expect(replaced).toBe(true)
	TestUtils.drain(fixture)
	expect(#TestUtils.kind(fixture, player, "BaselineEnd")).toBe(2)
	expect(#TestUtils.kind(fixture, player, "ActorHalt")).toBe(0)
end)

for _, unit: string in { "connections", "streams", "prepares", "measurements", "encodes", "sends" } do
	it("defers unsent work before draining when the " .. unit .. " budget is unavailable", function()
		local player: Player = TestUtils.player(fixture)
		TestUtils.actor(fixture, nil)
		fixture.options.workLimits = { [unit] = 0 }

		local runtime: Types.ActorAwarenessRuntime = TestUtils.start(fixture)
		TestUtils.ready(fixture, player)
		runtime:Step(32768, 64)
		expect(fixture.deliveries).toEqual({})
		fixture.options.workLimits = nil
		TestUtils.drain(fixture)
		expect(#TestUtils.kind(fixture, player, "BaselineEnd")).toBe(1)
		expect(fixture.faults).toEqual({})
	end)
end

it("bounds recovery captures while another live Actor makes progress and eventually drains every baseline", function()
	local player: Player = TestUtils.player(fixture)
	local actors: { ActorTypes.Actor } = {}

	for _ = 1, 7 do
		table.insert(actors, TestUtils.actor(fixture, nil))
	end

	local runtime: Types.ActorAwarenessRuntime = TestUtils.start(fixture)
	TestUtils.ready(fixture, player)
	TestUtils.drain(fixture)
	fixture.deliveries = {}

	for index = 1, 6 do
		for value = 11, 16 do
			fixture.publicDomain.value = value
			fixture.publicDomain.callbacks[actors[index]]({ { id = "Changed", payload = value } })
		end
	end

	fixture.publicDomain.value = 17
	fixture.publicDomain.callbacks[actors[7]]({ { id = "Changed", payload = 17 } })
	fixture.options.workLimits = { captures = 1 }

	for _ = 1, 32 do
		runtime:Step(32768, 64)
		local work = (runtime :: any).work

		if work ~= nil then
			for unit, used in work.used do
				expect(used <= work.limits[unit]).toBe(true)
			end

			expect(work.used.captures <= 1).toBe(true)
		end
	end

	expect(#TestUtils.kind(fixture, player, "Commit")).toBe(1)
	expect(#TestUtils.kind(fixture, player, "BaselineEnd")).toBe(6)
	expect(fixture.faults).toEqual({})
end)

it("cancels an obsolete staged Actor record when another send retires that Actor", function()
	local first: Player = TestUtils.player(fixture)
	local second: Player = TestUtils.player(fixture)
	local actor: ActorTypes.Actor = TestUtils.actor(fixture, nil)
	local runtime: Types.ActorAwarenessRuntime = TestUtils.start(fixture)
	TestUtils.ready(fixture, first)
	TestUtils.ready(fixture, second)

	fixture.dependencies.SendReliable = function(player: Player, payload: buffer): (boolean, string?)
		table.insert(fixture.deliveries, { player = player, payload = payload })

		if player == first then
			runtime:OnActorUnregistering(actor)
			runtime:Step(32768, 64)
		end

		return true, nil
	end

	runtime:Step(32768, 64)
	expect(TestUtils.records(fixture, second)).toEqual({})
	TestUtils.drain(fixture)
	expect(#TestUtils.kind(fixture, second, "ActorRemove")).toBe(1)
	expect(#TestUtils.kind(fixture, second, "BaselineBegin")).toBe(0)
end)

it("retains the oldest staged causal position when send reentry replaces unsent history", function()
	local first: Player = TestUtils.player(fixture)
	local second: Player = TestUtils.player(fixture)
	local actor: ActorTypes.Actor = TestUtils.actor(fixture, nil)
	local runtime: Types.ActorAwarenessRuntime = TestUtils.start(fixture)
	TestUtils.ready(fixture, first)
	TestUtils.ready(fixture, second)
	TestUtils.drain(fixture)
	fixture.deliveries = {}
	fixture.publicDomain.value = 11
	fixture.publicDomain.callbacks[actor]({ { id = "Changed", payload = 11 } })
	local requester: Player? = nil

	fixture.dependencies.SendReliable = function(player: Player, payload: buffer): (boolean, string?)
		table.insert(fixture.deliveries, { player = player, payload = payload })

		if requester == nil then
			local target: Player = if player == first then second else first
			requester = target
			local reservation = runtime:ReserveCommandResult(target, 1)
			assert(reservation ~= nil, "Expected bounded result reservation")
			local result: buffer = buffer.create(1)
			buffer.writeu8(result, 0, Constants.RESULT_KIND)
			expect(reservation.Commit(result)).toBe(true)

			for value = 12, 17 do
				fixture.publicDomain.value = value
				fixture.publicDomain.callbacks[actor]({ { id = "Changed", payload = value } })
			end
		end

		return true, nil
	end

	runtime:Step(32768, 64)
	TestUtils.drain(fixture)
	local timeline: { string } = {}

	for _, delivery in fixture.deliveries do
		if delivery.player ~= requester then
			continue
		end

		if buffer.readu8(delivery.payload, 0) == Constants.RESULT_KIND then
			table.insert(timeline, "Result")
		else
			local records: { SharedTypes.ActorStreamRecord }? = fixture.codec.Decode(delivery.payload)
			assert(records ~= nil, "Expected actual Actor envelope")

			for _, record in records do
				table.insert(timeline, record.kind)
			end
		end
	end

	expect(timeline[1]).toBe("BaselineBegin")
	expect(timeline[#timeline - 1]).toBe("BaselineEnd")
	expect(timeline[#timeline]).toBe("Result")
	expect(fixture.faults).toEqual({})
end)

afterEach(function()
	Streams.HasWork = originalHasWork
	Streams.HasWorkThrough = originalHasWorkThrough
	TestUtils.destroy(fixture)
end)

it("does not repeatedly inspect a stream already staged in the same pump", function()
	local player: Player = TestUtils.player(fixture)
	TestUtils.actor(fixture, nil)
	local runtime: Types.ActorAwarenessRuntime = TestUtils.start(fixture)
	TestUtils.ready(fixture, player)
	local inspections: number = 0

	Streams.HasWork = function(self: Streams.Stream): boolean
		inspections += 1

		return originalHasWork(self)
	end

	runtime:Step(32768, 64)
	expect(#TestUtils.kind(fixture, player, "BaselineBegin")).toBe(1)
	expect(inspections <= 2).toBe(true)
end)

it("sends a result ahead of newer Actor work without scanning every active Actor", function()
	local player: Player = TestUtils.player(fixture)
	local actors: { ActorTypes.Actor } = {}

	for _ = 1, 256 do
		table.insert(actors, TestUtils.actor(fixture, nil))
	end

	local runtime: Types.ActorAwarenessRuntime = TestUtils.start(fixture)
	TestUtils.ready(fixture, player)

	for _ = 1, 160 do
		runtime:Step(32768, 256)
	end

	expect(#TestUtils.kind(fixture, player, "BaselineEnd")).toBe(#actors)
	fixture.deliveries = {}

	local reservation: Types.CommandReservation? = runtime:ReserveCommandResult(player, 1)
	assert(reservation ~= nil, "Expected result reservation")
	local result: buffer = buffer.create(1)
	buffer.writeu8(result, 0, Constants.RESULT_KIND)
	expect(reservation.Commit(result)).toBe(true)

	for _, actor: ActorTypes.Actor in actors do
		fixture.publicDomain.value = 11
		fixture.publicDomain.callbacks[actor]()
	end

	local inspections: number = 0

	Streams.HasWorkThrough = function(self: Streams.Stream, order: number): boolean
		inspections += 1

		return originalHasWorkThrough(self, order)
	end

	runtime:Step(32768, 1)
	expect(#fixture.deliveries).toBe(1)
	expect(fixture.deliveries[1].payload).toBe(result)
	expect(inspections <= 2).toBe(true)
end)
