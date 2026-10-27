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
local Budget = require(KRF.server.Networking.utils.ReliableWorkBudget)
local TestUtils = require(script.Parent.Parent.Utils.Networking.AwarenessTestUtils)
local fixture: TestUtils.Fixture
local runtime: Types.ActorAwarenessRuntime
local internal: any
local encodes: number

beforeEach(function()
	fixture = TestUtils.new()
	runtime = TestUtils.start(fixture)
	internal = runtime
	local encode = internal.codec.EncodeBaseline
	encodes = 0

	internal.codec.EncodeBaseline = function(domains: any): (buffer?, string?)
		encodes += 1

		return encode(domains)
	end
end)

afterEach(function()
	TestUtils.destroy(fixture)
end)

it("shares one materialization across anchored recipients without spending their capture turns", function()
	local actor = TestUtils.actor(fixture, nil)
	local players: { Player } = {}

	fixture.options.workLimits = { captures = 1 }

	for _ = 1, 8 do
		local player = TestUtils.player(fixture)
		table.insert(players, player)
		TestUtils.ready(fixture, player)
	end

	fixture.publicDomain.value = 12
	fixture.publicDomain.callbacks[actor]({ { id = "Changed", payload = 12 } })
	runtime:Step(32768, 128)
	expect(encodes).toBe(1)
	expect(internal.delivery.work.used.captures).toBe(1)

	for _, player in players do
		expect(#TestUtils.kind(fixture, player, "BaselineBegin")).toBe(1)
		expect(internal.connections[player].captures.count).toBe(0)
	end

	fixture.options.workLimits = { captures = 0 }
	TestUtils.drain(fixture)

	for _, player in players do
		local handle = assert(runtime:GetHandle(player, actor))
		expect(TestUtils.baseline(fixture, player, handle)).toEqual({ ["Game.Public"] = { value = 10 } })
		local commits = TestUtils.kind(fixture, player, "Commit")
		expect(#commits).toBe(1)
		expect(commits[1].events).toEqual({ { domainId = "Game.Public", eventId = "Changed", payload = 12 } })
	end

	expect(encodes).toBe(1)
	expect(internal.backlog.records).toBe(0)
	expect(internal.backlog.bytes).toBe(0)
end)

it("keeps shared-body reuse inside preparation, record, byte and send budgets", function()
	TestUtils.actor(fixture, nil)
	local players: { Player } = {}

	for _ = 1, 3 do
		local player = TestUtils.player(fixture)
		table.insert(players, player)
		TestUtils.ready(fixture, player)
	end

	runtime:Step(256, 1)
	expect(encodes).toBe(1)
	fixture.deliveries = {}
	fixture.options.workLimits = { captures = 0, prepares = 0 }
	runtime:Step(256, 1)
	expect(fixture.deliveries).toEqual({})
	fixture.options.workLimits = { captures = 0, sends = 0 }
	runtime:Step(256, 1)
	expect(fixture.deliveries).toEqual({})
	fixture.options.workLimits = { captures = 0 }
	runtime:Step(1, 1)
	expect(fixture.deliveries).toEqual({})

	for _ = 1, 32 do
		local previous = #fixture.deliveries
		runtime:Step(256, 1)
		expect(#fixture.deliveries - previous <= 1).toBe(true)

		for index = previous + 1, #fixture.deliveries do
			local payload = fixture.deliveries[index].payload
			expect(buffer.len(payload) <= 256).toBe(true)
			expect(#assert(fixture.codec.Decode(payload))).toBe(1)
		end
	end

	for _, player in players do
		expect(#TestUtils.kind(fixture, player, "BaselineEnd")).toBe(1)
	end

	expect(encodes).toBe(1)
	expect(internal.backlog.records).toBe(0)
end)

it("anchors many joins synchronously but bounds all projection and encoding through capture turns", function()
	local actors: { ActorTypes.Actor } = {}

	for _ = 1, 7 do
		table.insert(actors, TestUtils.actor(fixture, nil))
	end

	local players: { Player } = {}

	fixture.options.workLimits = { captures = 1 }

	for _ = 1, 3 do
		local player = TestUtils.player(fixture)
		table.insert(players, player)
		TestUtils.ready(fixture, player)

		for _, actor in actors do
			local stream = internal.connections[player].actors[actor]
			expect(stream.fence).toBe(fixture.publication:GetActorSequence(actor))
		end
	end

	expect(encodes).toBe(0)
	expect(internal.backlog.records).toBe(21)

	for _ = 1, 64 do
		local previous = encodes
		runtime:Step(32768, 128)
		expect(encodes - previous <= 1).toBe(true)

		if internal.delivery.work ~= nil then
			expect(internal.delivery.work.used.captures <= 1).toBe(true)
		end
	end

	for _, player in players do
		expect(#TestUtils.kind(fixture, player, "BaselineEnd")).toBe(7)
	end

	expect(internal.backlog.records).toBe(0)
	expect(internal.backlog.bytes).toBe(0)
end)

it("removes a shared-body capture head using one bounded priority inspection", function()
	local player = TestUtils.player(fixture)
	TestUtils.actor(fixture, nil)
	TestUtils.actor(fixture, nil)
	TestUtils.ready(fixture, player)
	local connection = internal.connections[player]
	local stream = connection.captures.first.value
	internal.projections:Project(stream.actor, stream.baseline.projection)
	expect(encodes).toBe(1)
	local work = Budget.new(8, { captures = 1, priorities = 1 })
	internal.delivery.captures:Prioritize(internal.delivery.active, work, 8)
	expect(stream.captureNode.queue).toBeNil()
	expect(connection.captures.count).toBe(1)
	expect(work.used.captures).toBe(0)
	expect(work.used.priorities).toBe(1)
	internal.delivery.captures:Prioritize(internal.delivery.active, work, 8)
	expect(work.used.priorities).toBe(1)
	fixture.options.workLimits = { captures = 1 }
	TestUtils.drain(fixture)
	expect(encodes).toBe(2)
	expect(#TestUtils.kind(fixture, player, "BaselineEnd")).toBe(2)
	expect(internal.backlog.records).toBe(0)
end)

it("preserves the Ready anchor and every post-fence semantic event while encoding is postponed", function()
	local actor = TestUtils.actor(fixture, nil)
	local player = TestUtils.player(fixture)
	TestUtils.ready(fixture, player)
	expect(encodes).toBe(0)
	fixture.options.workLimits = { captures = 0 }
	fixture.publicDomain.value = 12
	fixture.publicDomain.callbacks[actor]({ { id = "Changed", payload = 12 } })
	runtime:Step(32768, 128)
	expect(encodes).toBe(0)
	expect(fixture.deliveries).toEqual({})
	fixture.options.workLimits = nil
	TestUtils.drain(fixture)
	local handle = assert(runtime:GetHandle(player, actor))
	expect(TestUtils.baseline(fixture, player, handle)).toEqual({ ["Game.Public"] = { value = 10 } })
	local commits = TestUtils.kind(fixture, player, "Commit")
	expect(#commits).toBe(1)
	expect(commits[1].events).toEqual({ { domainId = "Game.Public", eventId = "Changed", payload = 12 } })
end)

it("anchors resync before returning and rejects duplicates without encoding or moving its fence", function()
	local actor = TestUtils.actor(fixture, nil)
	local player = TestUtils.player(fixture)
	TestUtils.ready(fixture, player)
	TestUtils.drain(fixture)
	fixture.deliveries = {}
	encodes = 0
	local handle = assert(runtime:GetHandle(player, actor))
	local admitted, reason = runtime:RequestReplacementBaseline(player, handle)
	expect(admitted).toBe(true)
	expect(reason).toBeNil()
	expect(encodes).toBe(0)
	fixture.publicDomain.value = 13
	fixture.publicDomain.callbacks[actor]({ { id = "Changed", payload = 13 } })
	admitted, reason = runtime:RequestReplacementBaseline(player, handle)
	expect(admitted).toBe(false)
	expect(reason).toBe("BaselineAlreadyPending")
	TestUtils.drain(fixture)
	expect(TestUtils.baseline(fixture, player, handle)).toEqual({ ["Game.Public"] = { value = 10 } })
	expect(#TestUtils.kind(fixture, player, "Commit")).toBe(1)
end)

it("reconciles both association anchors without encoding in the association callback", function()
	local first = TestUtils.player(fixture)
	local second = TestUtils.player(fixture)
	local actor = TestUtils.actor(fixture, first)
	TestUtils.ready(fixture, first)
	TestUtils.ready(fixture, second)
	TestUtils.drain(fixture)
	fixture.deliveries = {}
	encodes = 0
	TestUtils.associate(fixture, actor, second)
	expect(encodes).toBe(0)
	fixture.ownerDomain.value = 21
	fixture.ownerDomain.callbacks[actor]({ { id = "Changed", payload = 21 } })
	fixture.options.workLimits = { captures = 1 }
	TestUtils.drain(fixture)

	expect(TestUtils.baseline(fixture, first, assert(runtime:GetHandle(first, actor)))).toEqual({
		["Game.Public"] = { value = 10 },
	})

	expect(TestUtils.baseline(fixture, second, assert(runtime:GetHandle(second, actor)))).toEqual({
		["Game.Public"] = { value = 10 },
		["Game.Private"] = { value = 20 },
	})

	expect(#TestUtils.kind(fixture, first, "Commit")).toBe(0)
	expect(#TestUtils.kind(fixture, second, "Commit")).toBe(1)
end)

for _, cancellation: string in { "retire", "disconnect", "destroy" } do
	it("releases an unencoded anchor on " .. cancellation .. " without running projection", function()
		local actor = TestUtils.actor(fixture, nil)
		local player = TestUtils.player(fixture)
		TestUtils.ready(fixture, player)
		expect(internal.backlog.records).toBe(1)
		expect(encodes).toBe(0)

		if cancellation == "retire" then
			runtime:OnActorUnregistering(actor)
		elseif cancellation == "disconnect" then
			TestUtils.close(fixture, player)
		else
			runtime:Destroy()
		end

		TestUtils.drain(fixture)
		expect(encodes).toBe(0)
		expect(internal.backlog.records).toBe(0)
		expect(internal.backlog.bytes).toBe(0)
		expect(internal.projections.baselines[actor] == nil).toBe(true)
	end)
end

it("refuses anchor retention before encoding when aggregate capacity is exhausted and recovers later", function()
	local actor = TestUtils.actor(fixture, nil)
	local player = TestUtils.player(fixture)

	internal.backlog.limits.maxBytes = 1
	TestUtils.ready(fixture, player)
	expect(encodes).toBe(0)
	expect(internal.backlog.records).toBe(0)
	expect(internal.projections.baselines[actor] == nil).toBe(true)

	for _ = 1, 64 do
		runtime:Step(32768, 128)
	end

	expect(encodes).toBe(0)
	internal.backlog.limits.maxBytes = 4096

	for _ = 1, 64 do
		runtime:Step(32768, 128)
	end

	expect(#TestUtils.kind(fixture, player, "BaselineEnd")).toBe(1)
	expect(internal.backlog.records).toBe(0)
end)
