--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local ActorTypes = require(KRF.server.Actor.types)
local Types = require(KRF.server.Networking.types)
local SharedTypes = require(KRF.shared.Networking.types)
local Delivery = require(KRF.server.Networking.utils.ActorDeliveryScheduler)
local Connections = require(KRF.server.Networking.utils.ActorRecipientConnection)
local Streams = require(KRF.server.Networking.utils.ActorRecipientStream)
local Constants = require(KRF.shared.Networking.utils.ActorProtocolConstants)
local TestUtils = require(script.Parent.Parent.Utils.Networking.AwarenessTestUtils)
local fixture: TestUtils.Fixture
local originalHasWork = Streams.HasWork
local originalPrepare = Streams.Prepare
local pumps = 0

type Owners = {
	delivery: Delivery.Runtime,
	connections: { [Player]: Connections.Connection },
	backlog: { records: number, bytes: number },
}

beforeEach(function()
	fixture = TestUtils.new()
	pumps = 0
end)

afterEach(function()
	Streams.HasWork, Streams.Prepare = originalHasWork, originalPrepare
	TestUtils.destroy(fixture)
end)

local function pump(runtime: Types.ActorAwarenessRuntime, owners: Owners, bytes: number, records: number): ()
	runtime:Step(bytes, records)
	local work = owners.delivery.work

	if work ~= nil then
		for unit, used in work.used do
			assert(used <= work.limits[unit], "Exceeded attempted-work budget")
		end
	end

	assert(owners.backlog.records <= Constants.BACKLOG_RECORDS, "Exceeded backlog record cap")
	assert(owners.backlog.bytes <= Constants.BACKLOG_BYTES, "Exceeded backlog byte cap")

	for _, connection in owners.connections do
		assert(connection.transferCount <= Constants.MAX_PENDING_BASELINES, "Exceeded transfer cap")
	end

	-- Cooperative test hosting only. Every assertion still uses fixed pump/work
	-- counts; no real Heartbeat is installed on this injected awareness runtime.
	pumps += 1

	if pumps % 32 == 0 then
		task.wait()
	end
end

local function observed(kind: string): { [Player]: number }
	local counts: { [Player]: number } = {}

	-- Decode each packet once, rather than rescan the entire transcript for each
	-- recipient. Large simulated populations should not stall the Studio plugin.
	for _, delivery in fixture.deliveries do
		for _, record in assert(fixture.codec.Decode(delivery.payload)) do
			if record.kind == kind then
				counts[delivery.player] = (counts[delivery.player] or 0) + 1

				if record.kind == "Commit" then
					assert(next(record.events) == nil, "State coalescing invented semantic events")
					assert(#record.patches == 1, "Expected exactly one visible-domain patch")
					local patch = record.patches[1]

					assert(
						patch.domainId == "Game.Public" and patch.patch.kind == "Replace",
						"Expected public replacement"
					)

					assert(patch.patch.value == 30, "Coalescing lost newest authoritative truth")
				end
			end
		end
	end

	return counts
end

for _, population in
	{
		{ actors = 1, recipients = 1 },
		{ actors = 1, recipients = 8 },
		{ actors = 1, recipients = 32 },
		{ actors = 16, recipients = 1 },
		{ actors = 16, recipients = 8 },
		{ actors = 16, recipients = 32 },
		{ actors = 64, recipients = 1 },
		{ actors = 64, recipients = 8 },
		{ actors = 64, recipients = 32 },
		{ actors = 128, recipients = 8 },
	}
do
	it(
		"bounds actual work and coalesced truth for "
			.. population.actors
			.. " Actors / "
			.. population.recipients
			.. " simulated recipients",
		function()
			local actors: { ActorTypes.Actor } = {}
			local players: { Player } = {}

			for _ = 1, population.actors do
				table.insert(actors, TestUtils.actor(fixture))
			end

			local runtime = TestUtils.start(fixture)
			local owners: Owners = runtime :: any

			for _ = 1, population.recipients do
				local player = TestUtils.player(fixture)
				table.insert(players, player)
				TestUtils.ready(fixture, player)
			end

			local streams = population.actors * population.recipients

			for _ = 1, streams * 4 + 16 do
				pump(runtime, owners, 32768, 16)

				if owners.delivery.active.count == 0 then
					break
				end
			end

			local baselines = observed("BaselineEnd")

			for _, player in players do
				expect(baselines[player]).toBe(population.actors)
			end

			expect(owners.backlog.records).toBe(0)
			expect(owners.backlog.bytes).toBe(0)
			fixture.deliveries = {}
			local inspected, prepared = 0, 0

			Streams.HasWork = function(self: Streams.Stream): boolean
				inspected += 1

				return originalHasWork(self)
			end

			Streams.Prepare = function(self: Streams.Stream, ...): (SharedTypes.ActorStreamRecord?, number?)
				prepared += 1

				return originalPrepare(self, ...)
			end

			for _ = 1, 64 do
				pump(runtime, owners, 32768, 16)
				expect(owners.delivery.work).toBeNil()
			end

			expect(inspected).toBe(0)
			expect(prepared).toBe(0)
			expect(fixture.deliveries).toEqual({})
			Streams.HasWork, Streams.Prepare = originalHasWork, originalPrepare

			-- Twenty writes per Actor retain exactly one newest state per recipient.
			for _, actor in actors do
				for value = 11, 30 do
					fixture.publicDomain.value = value
					fixture.publicDomain.callbacks[actor]()
				end
			end

			expect(owners.backlog.records).toBe(streams)

			for _ = 1, streams + 16 do
				pump(runtime, owners, 32768, 16)

				if owners.delivery.active.count == 0 then
					break
				end
			end

			local commits = observed("Commit")

			for _, player in players do
				expect(commits[player]).toBe(population.actors)
			end

			if population.actors > 1 and population.recipients < 16 then
				expect(#fixture.deliveries < streams).toBe(true)
			end

			expect(owners.backlog.records).toBe(0)
			expect(owners.backlog.bytes).toBe(0)
			expect(fixture.faults).toEqual({})
		end,
		-- The host deadline is not a performance assertion. These new population
		-- fixtures yield cooperatively; existing tests/runner deadlines are unchanged.
		30000
	)
end

it("serves intermittent Actors on every recipient while a hot Actor remains continuously eligible", function()
	local actors: { ActorTypes.Actor } = {}

	for _ = 1, 128 do
		table.insert(actors, TestUtils.actor(fixture))
	end

	local runtime = TestUtils.start(fixture)
	local owners: Owners = runtime :: any
	local players: { Player } = {}

	for _ = 1, 8 do
		local player = TestUtils.player(fixture)
		table.insert(players, player)
		TestUtils.ready(fixture, player)
	end

	for _ = 1, 4096 do
		pump(runtime, owners, 32768, 16)

		if owners.delivery.active.count == 0 then
			break
		end
	end

	for wave = 1, 4 do
		fixture.deliveries = {}
		fixture.publicDomain.value = 100 + wave
		fixture.publicDomain.callbacks[actors[wave + 1]]({ { id = "Changed", payload = 100 + wave } })

		for tick = 1, 24 do
			fixture.publicDomain.value = tick
			fixture.publicDomain.callbacks[actors[1]]()
			pump(runtime, owners, 32768, 4)
		end

		for _, player in players do
			local handle = runtime:GetHandle(player, actors[wave + 1])
			local events = 0

			for _, commit in TestUtils.kind(fixture, player, "Commit") do
				if commit.handle == handle then
					expect(commit.events).toEqual({
						{ domainId = "Game.Public", eventId = "Changed", payload = 100 + wave },
					})

					events += 1
				end
			end

			expect(events).toBe(1)
		end
	end

	expect(fixture.faults).toEqual({})
end)
