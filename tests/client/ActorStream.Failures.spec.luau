--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local Types = require(KRF.client.Networking.ActorStreamTypes)
local ClientTypes = require(KRF.client.types)
local Consumer = require(KRF.client.Networking.ActorStreamConsumer)
local Native: ClientTypes.Dependencies = require(KRF.client.Networking.NativeClientDependencies)
local TestUtils = require(script.Parent.Utils.ActorStreamTestUtils)
local ProtocolUtils = require(script.Parent.Parent.shared.Utils.Networking.ProtocolTestUtils)

local fixture: TestUtils.Fixture
beforeEach(function()
	fixture = TestUtils.new()
end)
afterEach(function()
	TestUtils.destroy(fixture)
	Consumer.Install(nil)
end)

it("retires removal received before initial identity without creating an N5 record", function()
	local runtime: Types.Runtime = TestUtils.start(fixture)
	expect(TestUtils.send(fixture, { { kind = "ActorRemove", handle = 7 } })).toBe(true)
	expect(runtime:GetByHandle(7)).toBeNil()
	expect(fixture.removed).toEqual({})
	local success: boolean, reason: string? = TestUtils.send(fixture, {
		{ kind = "BaselineBegin", handle = 7, actorId = "ActorA", generation = 1, totalBytes = 4 },
	})
	expect(success).toBe(false)
	expect(reason).toBe("RetiredActorHandle")
end)

it("rejects live work before baseline completion without delivering it to N5", function()
	TestUtils.start(fixture)
	local body: buffer = TestUtils.body(fixture)
	expect(TestUtils.send(fixture, {
		{
			kind = "BaselineBegin",
			handle = 1,
			actorId = "ActorA",
			generation = 1,
			totalBytes = buffer.len(body),
		},
	})).toBe(true)
	local success: boolean, reason: string? =
		TestUtils.send(fixture, { { kind = "Commit", handle = 1, revision = 1, patches = {}, events = {} } })
	expect(success).toBe(false)
	expect(reason).toBe("BaselineNotComplete")
	expect(fixture.commits).toEqual({})
end)

it("idempotently halts an incomplete assembly and frees capacity without removing its identity or Model", function()
	fixture.options.maxPendingBaselines = 1
	local runtime: Types.Runtime = TestUtils.start(fixture)
	local candidate: Types.Candidate = TestUtils.candidate(fixture, "ActorA")
	TestUtils.add(fixture, candidate)
	expect(TestUtils.send(fixture, {
		{ kind = "BaselineBegin", handle = 1, actorId = "ActorA", generation = 1, totalBytes = 4 },
	})).toBe(true)
	local original: Types.ActorRecord? = runtime:GetByHandle(1)
	assert(original ~= nil, "Expected admitted Actor")
	expect(TestUtils.send(fixture, {
		{ kind = "ActorHalt", handle = 1 },
		{ kind = "ActorHalt", handle = 1 },
	})).toBe(true)
	TestUtils.establish(fixture, 2, "ActorB")
	expect(runtime:GetByHandle(1)).toBe(original)
	expect(runtime:GetByModel(candidate.model)).toBe(original)
	expect(#fixture.baselines).toBe(1)
	expect(fixture.baselines[1].actor.actorId).toBe("ActorB")
	expect(fixture.removed).toEqual({})
	expect(fixture.unbound).toEqual({})
	expect(fixture.faults).toEqual({})
end)

for _, completedBaseline: boolean in { false, true } do
	it(
		"notifies the consumer once of terminal failure with completed baseline=" .. tostring(completedBaseline),
		function()
			local notifications: { string } = {}
			local onHalted: typeof(fixture.consumer.OnActorHalted) = fixture.consumer.OnActorHalted
			local onRemoved: typeof(fixture.consumer.OnActorRemoved) = fixture.consumer.OnActorRemoved
			fixture.consumer.OnActorHalted = function(actor: Types.ActorRecord): ()
				table.insert(notifications, "Halted")
				-- Terminal status must already hold when N5 receives the notification.
				local accepted: boolean, reason: string? = TestUtils.send(fixture, {
					{ kind = "Commit", handle = actor.handle, revision = 2, patches = {}, events = {} },
				})
				expect(accepted).toBe(false)
				expect(reason).toBe("ActorStreamHalted")
				onHalted(actor)
			end
			fixture.consumer.OnActorRemoved = function(actor: Types.ActorRecord): ()
				table.insert(notifications, "Removed")
				onRemoved(actor)
			end
			local runtime: Types.Runtime = TestUtils.start(fixture)
			local candidate: Types.Candidate = TestUtils.candidate(fixture, "ActorA")
			TestUtils.add(fixture, candidate)
			if completedBaseline then
				TestUtils.establish(fixture)
			else
				expect(TestUtils.send(fixture, {
					{ kind = "BaselineBegin", handle = 1, actorId = "ActorA", generation = 1, totalBytes = 4 },
				})).toBe(true)
			end
			local original: Types.ActorRecord? = runtime:GetByHandle(1)
			assert(original ~= nil, "Expected admitted Actor identity")
			expect(TestUtils.send(fixture, {
				{ kind = "ActorHalt", handle = 1 },
				{ kind = "ActorHalt", handle = 1 },
			})).toBe(true)
			expect(fixture.halted).toEqual({ original })
			expect(notifications).toEqual({ "Halted" })
			expect(#fixture.baselines).toBe(if completedBaseline then 1 else 0)
			expect(fixture.commits).toEqual({})
			expect(fixture.removed).toEqual({})
			expect(fixture.unbound).toEqual({})
			expect(runtime:GetByModel(candidate.model)).toBe(original)
			expect(TestUtils.send(fixture, { { kind = "ActorRemove", handle = 1 } })).toBe(true)
			expect(notifications).toEqual({ "Halted", "Removed" })
			expect(fixture.removed).toEqual({ original })
			expect(#fixture.unbound).toBe(1)
			expect(runtime:GetByHandle(1)).toBeNil()
		end
	)
end

it("rejects further data for a halted stream while still accepting its eventual removal", function()
	local runtime: Types.Runtime = TestUtils.start(fixture)
	local success: boolean, reason: string? = TestUtils.send(fixture, { { kind = "ActorHalt", handle = 1 } })
	expect(success).toBe(false)
	expect(reason).toBe("UnknownActorHandle")
	expect(runtime:GetByHandle(1)).toBeNil()
	expect(TestUtils.send(fixture, {
		{ kind = "BaselineBegin", handle = 1, actorId = "ActorA", generation = 1, totalBytes = 4 },
		{ kind = "ActorHalt", handle = 1 },
	})).toBe(true)
	success, reason = TestUtils.send(fixture, {
		{ kind = "Commit", handle = 1, revision = 1, patches = {}, events = {} },
	})
	expect(success).toBe(false)
	expect(reason).toBe("ActorStreamHalted")
	success, reason = TestUtils.send(fixture, {
		{ kind = "BaselineBegin", handle = 1, generation = 2, totalBytes = 4 },
	})
	expect(success).toBe(false)
	expect(reason).toBe("ActorStreamHalted")
	expect(fixture.baselines).toEqual({})
	expect(fixture.commits).toEqual({})
	expect(TestUtils.send(fixture, { { kind = "ActorRemove", handle = 1 } })).toBe(true)
	expect(runtime:GetByHandle(1)).toBeNil()
	expect(#fixture.removed).toBe(1)
	success, reason = TestUtils.send(fixture, { { kind = "ActorHalt", handle = 1 } })
	expect(success).toBe(false)
	expect(reason).toBe("RetiredActorHandle")
end)

it("rejects zero-length chunks and corrupt completed bodies, then accepts a fresh valid generation", function()
	TestUtils.start(fixture)
	expect(
		TestUtils.send(
			fixture,
			{ { kind = "BaselineBegin", handle = 1, actorId = "ActorA", generation = 1, totalBytes = 4 } }
		)
	).toBe(true)
	local success: boolean, reason: string? = TestUtils.send(
		fixture,
		{ { kind = "BaselineChunk", handle = 1, generation = 1, offset = 0, bytes = buffer.create(0) } }
	)
	expect(success).toBe(false)
	expect(reason).toBe("BaselineChunkOutOfBounds")
	local corrupt: buffer = buffer.create(4)
	buffer.writeu32(corrupt, 0, 1)
	success, reason = TestUtils.send(fixture, {
		{ kind = "BaselineChunk", handle = 1, generation = 1, offset = 0, bytes = corrupt },
		{ kind = "BaselineEnd", handle = 1, generation = 1, revision = 1 },
	})
	expect(success).toBe(false)
	expect(reason).toBe("InvalidActorBaseline")
	expect(fixture.baselines).toEqual({})
	TestUtils.replace(fixture, 1, 2, 2)
	expect(#fixture.baselines).toBe(1)
end)

it("rejects malformed buffers and all traffic after teardown", function()
	local runtime: Types.Runtime = TestUtils.start(fixture)
	local success: boolean, reason: string? = runtime:Handle(buffer.create(0))
	expect(success).toBe(false)
	expect(reason).toBe("MalformedActorPacket")
	local added: (Types.Candidate) -> () = fixture.added[1]
	local removed: (Instance) -> () = fixture.gone[1]
	local candidate: Types.Candidate = TestUtils.candidate(fixture, "ActorA")
	runtime:Destroy()
	added(candidate)
	removed(candidate.marker)
	success, reason = runtime:Handle(buffer.create(0))
	expect(success).toBe(false)
	expect(reason).toBe("ActorStreamDestroyed")
	expect(runtime:GetByModel(candidate.model)).toBeNil()
end)

it("reports a missing N5 consumer once across repeated packets", function()
	local runtime: Types.Runtime = TestUtils.start(fixture, true)
	for _ = 1, 3 do
		local success: boolean, reason: string? = runtime:Handle(buffer.create(0))
		expect(success).toBe(false)
		expect(reason).toBe("ActorStreamConsumerMissing")
	end
	expect(fixture.faults).toEqual({ "ActorStreamConsumerMissing" })
end)

it("installs the private N5 consumer in the native phase and stops its retained receiver on cleanup", function()
	Consumer.Install(fixture.consumer)
	expect(Consumer.Get()).toBe(fixture.consumer)
	local receiver: ((any) -> ())? = nil
	local success: boolean, reason: string?, cleanup: (() -> ())? = Native.InstallConsumers(
		fixture.protocol,
		ProtocolUtils.manifest(),
		function(callback: (any) -> ())
			receiver = callback
		end
	)
	expect(success).toBe(true)
	expect(reason).toBeNil()
	assert(receiver ~= nil and cleanup ~= nil, "Expected native stream receiver and cleanup")
	local body: buffer = TestUtils.body(fixture)
	local payload: buffer?, encodeReason: string? = fixture.codec.Encode({
		{ kind = "BaselineBegin", handle = 1, actorId = "ActorA", generation = 1, totalBytes = buffer.len(body) },
		{ kind = "BaselineChunk", handle = 1, generation = 1, offset = 0, bytes = body },
		{ kind = "BaselineEnd", handle = 1, generation = 1, revision = 1 },
	})
	assert(payload ~= nil, encodeReason)
	receiver(payload)
	expect(#fixture.baselines).toBe(1)
	cleanup()
	cleanup()
	receiver(payload)
	expect(#fixture.baselines).toBe(1)
	Consumer.Install(nil)
	expect(Consumer.Get()).toBeNil()
	local rejected: boolean = pcall(Native.InstallConsumers, fixture.protocol, nil, nil)
	expect(rejected).toBe(false)
end)
