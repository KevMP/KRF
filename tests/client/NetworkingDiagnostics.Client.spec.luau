--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local Client = require(KRF.client)
local Types = require(KRF.client.Networking.types)
local SharedTypes = require(KRF.shared.Networking.types)
local Commands: Types.CommandRuntime = require(KRF.client.Networking.CommandRuntime)
local Hints: Types.HintRuntime = require(KRF.client.Networking.HintRuntime)
local Diagnostics = require(KRF.client.Networking.NetworkingDiagnostics)
local State = require(KRF.client.Networking.utils.NetworkingDiagnosticsState)
local Native = require(KRF.client.Networking.utils.NativeClientDependencies)
local Schema = require(KRF.shared.Networking.Schema)
local Wire = require(KRF.shared.Networking.HintCodec)
local Manifest = require(KRF.shared.Networking.ManifestCompiler)
local TestUtils = require(script.Parent.Utils.CommandClientTestUtils)
local ClientUtils = require(script.Parent.Utils.ClientTestUtils)
local StreamUtils = require(script.Parent.Utils.ActorStreamTestUtils)
local ProtocolUtils = require(script.Parent.Parent.shared.Utils.Networking.ProtocolTestUtils)
local Clock = require(script.Parent.Parent.shared.Utils.TestClock)
local originalStep = Native.ObserveStep
local fixture: TestUtils.Fixture
local clock = Clock.new(100)
local tick: (() -> ())?

beforeEach(function()
	fixture = TestUtils.new()
	clock = Clock.new(100)
	Native.Now, Native.ScheduleTimeout = clock.Now, clock.Schedule
	tick = nil

	Native.ObserveStep = function(callback: () -> ()): () -> ()
		tick = callback

		return function(): () end
	end
end)

afterEach(function()
	fixture.cleanup()
	Native.ObserveStep = originalStep
end)

it("counts one uncertainty notification while retaining metadata for a late definitive outcome", function()
	TestUtils.ready(fixture)
	local owner = assert(State.Get())

	for _ = 1, 3 do
		expect((Commands.Send("Game.Ping"))).never.toBeNil()
	end

	expect(owner:Snapshot().gauges.clientCommandPending.current).toBe(3)
	expect(owner:Snapshot().gauges.clientCommandMetadataBytes.current).toBe(3 * (32 + #"Game.Ping"))
	TestUtils.result(fixture, 1, "Accepted")
	-- Let the actual reliable consumer resume after each callback fence.
	task.wait()
	TestUtils.result(fixture, 2, "Unknown", "CommandHandlerFault")
	task.wait()
	TestUtils.result(fixture, 2, "Unknown", "CommandHandlerFault")
	task.wait()
	expect(owner:Snapshot().counters.commandsAccepted).toBe(1)
	expect(owner:Snapshot().counters.commandsUncertain).toBe(1)
	expect(owner:Snapshot().gauges.clientCommandPending.current).toBe(2)
	TestUtils.result(fixture, 2, "Rejected", "LateDenied")
	task.wait()
	expect(owner:Snapshot().counters.commandsRejected).toBe(1)
	expect(owner:Snapshot().gauges.clientCommandPending.current).toBe(1)
	Client._ResetForTests()
	Client._ResetForTests()
	expect(owner:Snapshot().counters.commandsUncertain).toBe(2)
	expect(owner:Snapshot().gauges.clientCommandPending.current).toBe(0)
	expect(owner:Snapshot().gauges.clientCommandMetadataBytes.current).toBe(0)
	expect(Diagnostics.GetClientSnapshot()).toBeNil()
end)

it("reports active assembly buffers and deferred reliable ownership and releases them once on teardown", function()
	TestUtils.ready(fixture)
	local owner = assert(State.Get())
	local body = StreamUtils.body(fixture.stream)

	TestUtils.records(
		fixture,
		{ { kind = "BaselineBegin", handle = 8, actorId = "ActorB", generation = 1, totalBytes = buffer.len(body) } }
	)

	expect(owner:Snapshot().gauges.clientBaselineAssemblies.current).toBe(1)
	expect(owner:Snapshot().gauges.clientBaselineBytes.current).toBe(2 * buffer.len(body))

	TestUtils.records(
		fixture,
		{ { kind = "BaselineBegin", handle = 8, generation = 2, totalBytes = buffer.len(body) } }
	)

	expect(owner:Snapshot().gauges.clientBaselineAssemblies.current).toBe(1)
	expect(owner:Snapshot().gauges.clientBaselineBytes.highWater).toBe(2 * buffer.len(body))
	TestUtils.records(fixture, { { kind = "ActorHalt", handle = 8 } })
	expect(owner:Snapshot().gauges.clientBaselineBytes.current).toBe(0)
	local id = assert(Commands.Send("Game.Ping"))
	TestUtils.result(fixture, id, "Accepted")
	local payload = assert(fixture.stream.codec.Encode({ { kind = "ActorRemove", handle = 999 } }))
	ClientUtils.emit(fixture.client, payload)
	local pending = owner:Snapshot()
	expect(pending.gauges.clientReliableDeferredRecords.current).toBe(1)
	expect(pending.gauges.clientReliableDeferredBytes.current).toBe(buffer.len(payload))
	Client._ResetForTests()
	expect(owner:Snapshot().gauges.clientReliableDeferredBytes.current).toBe(0)
	expect(owner:Snapshot().gauges.clientBaselineAssemblies.current).toBe(0)
	expect(owner:Snapshot().counters.clientReliableDeferredAdmitted).toBe(1)
	expect(owner:Snapshot().counters.clientReliableDeferredDropped).toBe(1)
	expect(pending.gauges.clientReliableDeferredRecords.current).toBe(1)
end)

it(
	"measures retained Hint data age after coalescing and distinguishes failed sends from successful local handoff",
	function()
		local receive: ((any, ...any) -> ())?
		local failSend = false

		fixture.client.transport.SendUnreliable = function(): ()
			if failSend then
				error("TransportFailure")
			end
		end

		fixture.client.transport.ConnectUnreliable = function(callback): () -> ()
			receive = callback

			return function(): () end
		end

		TestUtils.start(fixture)
		local original = ProtocolUtils.manifest()

		local metadata: SharedTypes.ProtocolManifest = {
			version = original.version,
			domains = original.domains,
			hints = {
				{
					id = "Game.Pulse",
					code = 0,
					direction = "ClientToServer",
					target = "None",
					mode = "Pulse",
					payload = Schema.U8,
				},
				{
					id = "Game.Sample",
					code = 1,
					direction = "ClientToServer",
					target = "None",
					mode = "Latest",
					payload = Schema.U8,
				},
				{
					id = "Game.Server",
					code = 2,
					direction = "ServerToClient",
					target = "None",
					mode = "Latest",
					payload = Schema.U8,
				},
			},
		}

		local protocol = assert(Manifest.Reconstruct(metadata))
		ClientUtils.emit(fixture.client, ProtocolUtils.encode({ kind = "Bootstrap", manifest = metadata }))
		ClientUtils.acknowledge(fixture.client)
		local owner = assert(State.Get())
		expect((Hints.Send("Game.Sample", nil, 1))).toBe(true)
		expect((Hints.Send("Game.Pulse", nil, 3))).toBe(true)
		clock.Advance(0.5)
		expect((Hints.Send("Game.Sample", nil, 2))).toBe(true)
		expect(owner:Snapshot().ages.hintSendQueueAgeSeconds).toBe(0.5)
		clock.Advance(0.5)
		local pump = assert(tick, "Expected installed Hint pump")
		pump()
		expect(owner:Snapshot().counters.hintsSent).toBe(2)
		expect(owner:Snapshot().counters.hintsCoalesced).toBe(1)
		expect(owner:Snapshot().maxima.hintSendQueueResidenceSeconds).toBe(1)
		expect(owner:Snapshot().ages.hintSendQueueAgeSeconds).toBeNil()
		expect((Hints.Send("Game.Pulse", nil, 4))).toBe(true)
		failSend = true
		pump()
		expect(owner:Snapshot().counters.hintsSent).toBe(2)
		expect(owner:Snapshot().counters.hintSendFailures).toBe(1)
		local codec = Wire.Compile(protocol, "ServerToClient")
		local packet = assert(codec.Pack({ assert(codec.EncodeRecord({ hintCode = 2, sequence = 2, payload = 5 })) }))
		local receiver = assert(receive, "Expected installed unreliable receiver")
		receiver(packet)
		receiver(packet)
		receiver(buffer.create(1))
		clock.Advance(0.25)
		expect(owner:Snapshot().ages.hintReceiveQueueAgeSeconds).toBe(0.25)
		pump()
		local snapshot = owner:Snapshot()
		expect(snapshot.counters.hintsReceived).toBe(1)
		expect(snapshot.counters.hintsStaleDropped).toBe(1)
		expect(snapshot.counters.hintsMalformed).toBe(1)
		expect(snapshot.counters.hintsDropped).toBe(2)
		expect(snapshot.maxima.hintReceiveQueueResidenceSeconds).toBe(0.25)
		expect(snapshot.gauges.hintLatestKeys.current).toBe(2)
		Client._ResetForTests()
		expect(owner:Snapshot().gauges.hintLatestKeys.current).toBe(0)
		expect(owner:GetAge("hintReceiveQueueAgeSeconds")).toBeNil()
	end
)

it(
	"counts recovery wait scheduling, duplicate starts and rate refusal without treating successful recovery as abandonment",
	function()
		TestUtils.ready(fixture)
		TestUtils.baseline(fixture)
		local owner = assert(State.Get())
		TestUtils.records(fixture, { { kind = "Commit", handle = 7, revision = 3, patches = {}, events = {} } })
		expect(owner:Snapshot().gauges.recoveryStreams.current).toBe(1)
		expect(owner:Snapshot().counters.resyncRequests).toBe(1)
		expect(owner:Snapshot().counters.resyncAdmitted).toBe(1)
		expect(owner:Snapshot().counters.recoveryBackoffs).toBe(1)

		TestUtils.records(
			fixture,
			{ { kind = "BaselineChunk", handle = 7, generation = 999, offset = 0, bytes = buffer.create(1) } }
		)

		expect(owner:Snapshot().counters.resyncDeduplicated).toBe(1)
		clock.Advance(3)
		expect(owner:Snapshot().counters.resyncAdmitted).toBe(3)
		expect(owner:Snapshot().counters.resyncRateLimited).toBe(0)
		local body = StreamUtils.body(fixture.stream)

		TestUtils.records(fixture, {
			{ kind = "BaselineBegin", handle = 7, generation = 2, totalBytes = buffer.len(body) },
			{ kind = "BaselineChunk", handle = 7, generation = 2, offset = 0, bytes = body },
			{ kind = "BaselineEnd", handle = 7, generation = 2, revision = 5 },
		})

		expect(owner:Snapshot().gauges.recoveryStreams.current).toBe(0)
		expect(owner:Snapshot().counters.recoveryAbandoned).toBe(0)
		TestUtils.records(fixture, { { kind = "Commit", handle = 7, revision = 7, patches = {}, events = {} } })
		expect(owner:Snapshot().counters.resyncAdmitted).toBe(4)

		TestUtils.records(fixture, {
			{ kind = "BaselineBegin", handle = 7, generation = 3, totalBytes = buffer.len(body) },
			{ kind = "BaselineChunk", handle = 7, generation = 3, offset = 0, bytes = body },
			{ kind = "BaselineEnd", handle = 7, generation = 3, revision = 8 },
		})

		TestUtils.records(fixture, { { kind = "Commit", handle = 7, revision = 10, patches = {}, events = {} } })
		expect(owner:Snapshot().counters.resyncRateLimited).toBe(1)
		Client._ResetForTests()
		Client._ResetForTests()
		expect(owner:Snapshot().gauges.recoveryStreams.current).toBe(0)
		expect(owner:Snapshot().counters.recoveryAbandoned).toBe(1)
	end
)
