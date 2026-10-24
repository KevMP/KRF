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
local Budget = require(KRF.server.Networking.utils.ReliableWorkBudget)
local TestUtils = require(script.Parent.Parent.Utils.Networking.AwarenessTestUtils)
local fixture: TestUtils.Fixture

beforeEach(function()
	fixture = TestUtils.new()
end)

afterEach(function()
	TestUtils.destroy(fixture)
end)

for _, population in
	{
		{ actors = 7, recipients = 1, records = 64 },
		{ actors = 1, recipients = 8, records = 64 },
		{ actors = 16, recipients = 8, records = 32 },
	}
do
	it(
		"shares a saturated capture budget across "
			.. population.actors
			.. " Actors and "
			.. population.recipients
			.. " recipients",
		function()
			local actors: { ActorTypes.Actor } = {}
			local players: { Player } = {}

			for _ = 1, population.actors do
				table.insert(actors, TestUtils.actor(fixture, nil))
			end

			for _ = 1, population.recipients do
				table.insert(players, TestUtils.player(fixture))
			end

			local runtime: Types.ActorAwarenessRuntime = TestUtils.start(fixture)

			for _, player in players do
				TestUtils.ready(fixture, player)
			end

			-- The shared helper supplies 32 tiny (8-record/256-byte) pumps. This
			-- larger fixture needs enough bounded opportunities for every baseline.
			for _ = 1, 8 do
				TestUtils.drain(fixture)
			end

			fixture.deliveries = {}
			fixture.options.workLimits = { captures = 1 }

			for _ = 1, math.max(32, population.actors * population.recipients + 16) do
				for _, actor in actors do
					for value = 11, 16 do
						fixture.publicDomain.value = value
						fixture.publicDomain.callbacks[actor]({ { id = "Changed", payload = value } })
					end
				end

				runtime:Step(32768, population.records)
				expect((runtime :: any).work.used.captures <= 1).toBe(true)
			end

			for _, player in players do
				local begins: { [number]: number } = {}

				for _, record in TestUtils.kind(fixture, player, "BaselineBegin") do
					begins[record.handle] = (begins[record.handle] or 0) + 1
				end

				for _, actor in actors do
					local handle = assert(runtime:GetHandle(player, actor))
					expect((begins[handle] or 0) >= 1).toBe(true)
				end
			end

			for _ = 1, 8 do
				TestUtils.drain(fixture)
			end

			for _, player in players do
				expect(#TestUtils.kind(fixture, player, "BaselineEnd")).toBe(population.actors)
			end

			expect(fixture.faults).toEqual({})
		end
	)
end

it("serves another capture behind an unresolved result and detaches the old opportunity on close", function()
	local blocked: Player = TestUtils.player(fixture)
	local healthy: Player = TestUtils.player(fixture)
	local actor: ActorTypes.Actor = TestUtils.actor(fixture, nil)
	local runtime: Types.ActorAwarenessRuntime = TestUtils.start(fixture)
	TestUtils.ready(fixture, blocked)
	TestUtils.drain(fixture)
	local reservation = assert(runtime:ReserveCommandResult(blocked, 1))

	for value = 11, 16 do
		fixture.publicDomain.value = value
		fixture.publicDomain.callbacks[actor]({ { id = "Changed", payload = value } })
	end

	TestUtils.ready(fixture, healthy)

	for _ = 1, 16 do
		runtime:Step(32768, 64)
	end

	expect(#TestUtils.kind(fixture, healthy, "BaselineEnd")).toBe(1)
	fixture.deliveries = {}
	fixture.options.workLimits = { captures = 1 }

	for value = 17, 22 do
		fixture.publicDomain.value = value
		fixture.publicDomain.callbacks[actor]({ { id = "Changed", payload = value } })
	end

	for _ = 1, 16 do
		runtime:Step(32768, 64)
	end

	expect(#TestUtils.kind(fixture, healthy, "BaselineEnd")).toBe(1)
	expect(#TestUtils.kind(fixture, blocked, "BaselineBegin")).toBe(0)
	local detached: Streams.Stream = (runtime :: any).connections[blocked].actors[actor]
	TestUtils.close(fixture, blocked)
	expect(reservation.Commit(buffer.create(1))).toBe(false)
	TestUtils.ready(fixture, blocked)
	local work = Budget.new(4)
	expect(detached:Prepare(512, true, 512, nil, work)).toBeNil()
	expect(work.used.captures).toBe(0)
	TestUtils.drain(fixture)
	expect(#TestUtils.kind(fixture, blocked, "BaselineEnd")).toBe(1)
	fixture.deliveries = {}

	for value = 23, 28 do
		fixture.publicDomain.value = value
		fixture.publicDomain.callbacks[actor]({ { id = "Changed", payload = value } })
	end

	TestUtils.drain(fixture)

	for _, player in { blocked, healthy } do
		expect(#TestUtils.kind(fixture, player, "BaselineEnd")).toBe(1)
	end

	expect(fixture.faults).toEqual({})
end)
