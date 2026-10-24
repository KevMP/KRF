--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local afterEach: any = JestGlobals.afterEach
local Types = require(KRF.server.Networking.types)
local Streams = require(KRF.server.Networking.utils.ActorRecipientStream)
local Order = require(KRF.server.Networking.utils.ActorStreamOrder)
local TestUtils = require(script.Parent.Parent.Utils.Networking.AwarenessTestUtils)
local fixture: TestUtils.Fixture? = nil

afterEach(function()
	if fixture ~= nil then
		TestUtils.destroy(fixture)
		fixture = nil
	end
end)

it("keeps the minimum causal position correct through head changes and arbitrary stream removal", function()
	local created = TestUtils.new()
	fixture = created
	local player: Player = TestUtils.player(created)

	for _ = 1, 16 do
		TestUtils.actor(created, nil)
	end

	local runtime: Types.ActorAwarenessRuntime = TestUtils.start(created)
	TestUtils.ready(created, player)
	local connection = (runtime :: any).connections[player]
	local heap: { Streams.Stream } = connection.orders
	local streams: { Streams.Stream } = {}
	local positions: { [Streams.Stream]: number } = {}

	for _, stream: Streams.Stream in connection.actors do
		table.insert(streams, stream)
		positions[stream] = 0

		stream.GetNextOrder = function(self: Streams.Stream): number?
			return positions[self]
		end
	end

	-- Positions model independent stream heads; their payload queues are untouched.
	for turn = 1, 160 do
		local stream: Streams.Stream = streams[(turn * 7) % #streams + 1]

		positions[stream] = if turn % 5 == 0 then nil else (turn * 13) % 41
		Order.Update(heap, stream)
		local earliest = math.huge

		for _, position in positions do
			earliest = math.min(earliest, position)
		end

		expect(Order.HasWorkThrough(heap, earliest - 1)).toBe(false)

		if earliest < math.huge then
			expect(Order.HasWorkThrough(heap, earliest)).toBe(true)
		end
	end

	for _, stream in streams do
		positions[stream] = nil
		Order.Update(heap, stream)
		Order.Update(heap, stream)
	end

	expect(Order.HasWorkThrough(heap, 4294967295)).toBe(false)
end)
