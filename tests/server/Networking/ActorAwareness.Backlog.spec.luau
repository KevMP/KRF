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
local TestUtils = require(script.Parent.Parent.Utils.Networking.AwarenessTestUtils)
local fixture: TestUtils.Fixture

beforeEach(function()
	fixture = TestUtils.new()

	local options: any = fixture.options

	options.backlogLimits = {
		maxRecords = 12,
		maxBytes = 4096,
		actorRecords = 6,
		actorBytes = 2048,
		recipientRecords = 8,
		recipientBytes = 2048,
		recoveryRecords = 2,
		recoveryBytes = 1024,
	}

	fixture.options.maxEvents = 32
end)

afterEach(function()
	TestUtils.destroy(fixture)
end)

it("bounds many individually valid streams and abandons only refused history", function()
	local actors: { ActorTypes.Actor } = {}

	for _ = 1, 4 do
		table.insert(actors, TestUtils.actor(fixture, nil))
	end

	local runtime: Types.ActorAwarenessRuntime = TestUtils.start(fixture)

	for _ = 1, 3 do
		TestUtils.ready(fixture, TestUtils.player(fixture))
	end

	TestUtils.drain(fixture)

	for _, actor in actors do
		fixture.publicDomain.callbacks[actor]({ { id = "Changed", payload = 11 } })
	end

	local pending, discontinuous = 0, 0

	for _, connection in (runtime :: any).connections do
		for _, stream in connection.actors do
			local status = stream.scheduler:GetStreamStatus(stream.key)
			pending += status.pendingRecords

			if stream.recapture then
				discontinuous += 1
				expect(status.needsBaseline).toBe(true)
				expect(status.pendingRecords).toBe(0)
			end
		end
	end

	expect(pending <= 10).toBe(true)
	expect(discontinuous > 0).toBe(true)
	TestUtils.drain(fixture)
	expect((runtime :: any).backlog.records).toBe(0)
	expect((runtime :: any).backlog.bytes).toBe(0)
end)

it("isolates a hot Actor while quieter streams keep their semantic history", function()
	local hot: ActorTypes.Actor = TestUtils.actor(fixture, nil)
	local quiet: ActorTypes.Actor = TestUtils.actor(fixture, nil)
	local player: Player = TestUtils.player(fixture)
	local runtime: Types.ActorAwarenessRuntime = TestUtils.start(fixture)
	TestUtils.ready(fixture, player)
	TestUtils.ready(fixture, TestUtils.player(fixture))
	TestUtils.drain(fixture)
	fixture.deliveries = {}

	for value = 11, 30 do
		fixture.publicDomain.value = value
		fixture.publicDomain.callbacks[hot]({ { id = "Changed", payload = value } })
	end

	fixture.publicDomain.callbacks[quiet]({ { id = "Changed", payload = 31 } })

	for _, connection in (runtime :: any).connections do
		local stream = connection.actors[quiet]
		expect(stream.recapture).toBe(false)
		expect(stream.scheduler:GetStreamStatus(stream.key).pendingEvents).toBe(1)
	end

	TestUtils.drain(fixture)
	local quietHandle = runtime:GetHandle(player, quiet)
	local events = 0

	for _, record in TestUtils.kind(fixture, player, "Commit") do
		if record.handle == quietHandle then
			events += #record.events
		end
	end

	expect(events).toBe(1)
	expect((runtime :: any).backlog.records).toBe(0)
end)

it("coalesces state and charges one shared payload across recipients", function()
	local actor: ActorTypes.Actor = TestUtils.actor(fixture, nil)
	local runtime: Types.ActorAwarenessRuntime = TestUtils.start(fixture)
	TestUtils.ready(fixture, TestUtils.player(fixture))
	TestUtils.ready(fixture, TestUtils.player(fixture))
	TestUtils.drain(fixture)
	fixture.publicDomain.value = 11
	fixture.publicDomain.callbacks[actor](nil)
	local bytes = (runtime :: any).backlog.bytes

	for value = 12, 30 do
		fixture.publicDomain.value = value
		fixture.publicDomain.callbacks[actor](nil)
	end

	expect((runtime :: any).backlog.records).toBe(2)
	-- Composed tails may be distinct objects; a fresh public commit is shared.
	TestUtils.drain(fixture)
	fixture.publicDomain.value = 31
	fixture.publicDomain.callbacks[actor](nil)
	expect((runtime :: any).backlog.bytes).toBe(bytes)
	TestUtils.drain(fixture)
	expect((runtime :: any).backlog.bytes).toBe(0)
end)

it("releases retirement, disconnect and replacement charges exactly once", function()
	local actor: ActorTypes.Actor = TestUtils.actor(fixture, nil)
	local player: Player = TestUtils.player(fixture)
	local runtime: Types.ActorAwarenessRuntime = TestUtils.start(fixture)
	TestUtils.ready(fixture, player)
	TestUtils.drain(fixture)
	fixture.publicDomain.callbacks[actor]({ { id = "Changed", payload = 11 } })
	expect((runtime :: any).backlog.records).toBe(1)
	local handle = assert(runtime:GetHandle(player, actor))
	expect(runtime:RequestReplacementBaseline(player, handle)).toBe(true)
	TestUtils.drain(fixture)
	expect((runtime :: any).backlog.records).toBe(0)
	fixture.publicDomain.callbacks[actor]({ { id = "Changed", payload = 12 } })
	runtime:OnActorUnregistering(actor)
	TestUtils.close(fixture, player)
	TestUtils.close(fixture, player)
	expect((runtime :: any).backlog.records).toBe(0)
	expect((runtime :: any).backlog.bytes).toBe(0)
end)

it("keeps staged payload charged through a reentrant send and frees it on unwind", function()
	local actor: ActorTypes.Actor = TestUtils.actor(fixture, nil)
	local player: Player = TestUtils.player(fixture)
	local runtime: Types.ActorAwarenessRuntime = TestUtils.start(fixture)
	TestUtils.ready(fixture, player)
	TestUtils.drain(fixture)
	fixture.publicDomain.callbacks[actor]({ { id = "Changed", payload = 11 } })

	fixture.dependencies.SendReliable = function(): (boolean, string?)
		TestUtils.close(fixture, player)
		expect((runtime :: any).backlog.records).toBe(1)

		return true, nil
	end

	runtime:Step(32768, 128)
	expect((runtime :: any).backlog.records).toBe(0)
	expect((runtime :: any).backlog.bytes).toBe(0)
end)

it("retains older replacement work ahead of a pending CommandResult", function()
	local actor: ActorTypes.Actor = TestUtils.actor(fixture, nil)
	local player: Player = TestUtils.player(fixture)
	local runtime: Types.ActorAwarenessRuntime = TestUtils.start(fixture)
	TestUtils.ready(fixture, player)
	TestUtils.drain(fixture)

	for value = 11, 20 do
		fixture.publicDomain.callbacks[actor]({ { id = "Changed", payload = value } })
	end

	local stream: any = (runtime :: any).connections[player].actors[actor]
	expect(stream.recapture).toBe(true)
	local reservation = assert(runtime:ReserveCommandResult(player, 32))
	local boundary: number = (runtime :: any).connections[player].egress.queue[1].order
	TestUtils.drain(fixture)
	expect(stream:HasWorkThrough(boundary)).toBe(false)
	reservation.Cancel()
	expect((runtime :: any).backlog.records).toBe(0)
end)

it("does not let one blocked recipient exhaust another recipient's Actor allowance", function()
	local blocked: Player = TestUtils.player(fixture)
	local healthy: Player = TestUtils.player(fixture)
	local actor: ActorTypes.Actor = TestUtils.actor(fixture, blocked)
	local runtime: Types.ActorAwarenessRuntime = TestUtils.start(fixture)
	TestUtils.ready(fixture, blocked)
	TestUtils.ready(fixture, healthy)
	TestUtils.drain(fixture)
	local reservation = assert(runtime:ReserveCommandResult(blocked, 32))
	local stream: any = (runtime :: any).connections[healthy].actors[actor]

	-- Owner-only events fill the blocked recipient before a healthy public
	-- stream attempts admission. Do not depend on dictionary iteration order.
	for value = 11, 15 do
		fixture.ownerDomain.callbacks[actor]({ { id = "Changed", payload = value } })
	end

	local commit: Types.PublicationFilteredCommit = {
		sequence = 100,
		patches = {},
		events = { { domainId = "Game.Public", eventId = "Changed", payload = 16 } },
	}

	stream:Enqueue(commit, 0)
	expect(stream.recapture).toBe(false)
	expect(stream.scheduler:GetStreamStatus(stream.key).pendingEvents).toBe(1)
	runtime:Step(32768, 128)

	expect(stream.generation).toBe(1)
	reservation.Cancel()
	TestUtils.drain(fixture)
	expect((runtime :: any).backlog.records).toBe(0)
end)

it("does not charge a replacement owner when projection closes and readies its old connection", function()
	local actor: ActorTypes.Actor = TestUtils.actor(fixture, nil)
	local player: Player = TestUtils.player(fixture)
	local runtime: Types.ActorAwarenessRuntime = TestUtils.start(fixture)
	TestUtils.ready(fixture, player)
	TestUtils.drain(fixture)
	local stream: any = (runtime :: any).connections[player].actors[actor]
	local project = stream.dependencies.Project

	stream.dependencies.Project = function(target: ActorTypes.Actor, recipient: Player): (any, any, any)
		local sequence, projected, reason = project(target, recipient)
		TestUtils.close(fixture, player)
		TestUtils.ready(fixture, player)

		return sequence, projected, reason
	end

	local accepted = runtime:RequestReplacementBaseline(player, assert(runtime:GetHandle(player, actor)))
	expect(accepted).toBe(false)
	expect((runtime :: any).backlog.records).toBe(1)
	TestUtils.drain(fixture)
	expect((runtime :: any).backlog.records).toBe(0)
end)

it("releases an explicitly destroyed stream's retained baseline exactly once", function()
	local actor: ActorTypes.Actor = TestUtils.actor(fixture, nil)
	local player: Player = TestUtils.player(fixture)
	local runtime: Types.ActorAwarenessRuntime = TestUtils.start(fixture)
	TestUtils.ready(fixture, player)
	local stream: any = (runtime :: any).connections[player].actors[actor]
	stream:Destroy()
	stream:Destroy()
	expect((runtime :: any).backlog.records).toBe(0)
	expect((runtime :: any).backlog.bytes).toBe(0)
end)

it("defers a baseline without halting and recovers after byte capacity returns", function()
	local actor: ActorTypes.Actor = TestUtils.actor(fixture, nil)
	local player: Player = TestUtils.player(fixture)
	local runtime: Types.ActorAwarenessRuntime = TestUtils.start(fixture)
	TestUtils.ready(fixture, player)
	TestUtils.drain(fixture)

	local internal: any = runtime
	internal.backlog.limits.maxBytes = 1

	local handle = assert(runtime:GetHandle(player, actor))
	local accepted, reason = runtime:RequestReplacementBaseline(player, handle)
	expect(accepted).toBe(false)
	expect(reason).toBe("ActorBaselineCapacity")

	for _ = 1, 4 do
		runtime:Step(32768, 128)
	end

	expect(internal.connections[player].actors[actor].recapture).toBe(true)
	expect(internal.backlog.bytes).toBe(0)
	expect(fixture.faults).toEqual({})
	internal.backlog.limits.maxBytes = 4096
	TestUtils.drain(fixture)
	expect(#TestUtils.kind(fixture, player, "BaselineEnd")).toBe(2)
	expect(internal.backlog.bytes).toBe(0)
end)

it("shares a baseline body's byte charge and admits other Actors as transfers complete", function()
	TestUtils.actor(fixture, nil)
	local first: Player = TestUtils.player(fixture)
	local second: Player = TestUtils.player(fixture)
	local runtime: Types.ActorAwarenessRuntime = TestUtils.start(fixture)
	TestUtils.ready(fixture, first)
	local internal: any = runtime
	local bytes: number = internal.backlog.bytes

	internal.backlog.limits.maxBytes = bytes
	TestUtils.ready(fixture, second)
	expect(internal.backlog.records).toBe(2)
	expect(internal.backlog.bytes).toBe(bytes)
	local deferred: ActorTypes.Actor = TestUtils.actor(fixture, nil)
	expect(internal.connections[first].actors[deferred].recapture).toBe(true)
	TestUtils.drain(fixture)
	expect(#TestUtils.kind(fixture, first, "BaselineEnd")).toBe(2)
	expect(#TestUtils.kind(fixture, second, "BaselineEnd")).toBe(2)
	expect(internal.backlog.records).toBe(0)
	expect(internal.backlog.bytes).toBe(0)
end)
