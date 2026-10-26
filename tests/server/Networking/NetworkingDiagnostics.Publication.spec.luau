--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local Types = require(KRF.server.Networking.types)
local State = require(KRF.server.Networking.utils.NetworkingDiagnosticsState)
local Diagnostics = require(KRF.server.Networking.NetworkingDiagnostics)
local TestUtils = require(script.Parent.Parent.Utils.Networking.AwarenessTestUtils)
local fixture: TestUtils.Fixture
local runtime: Types.ActorAwarenessRuntime
local player: Player
local now: number

beforeEach(function()
	State.Start()
	fixture = TestUtils.new()
	now = 100

	fixture.dependencies.Now = function(): number
		return now
	end

	player = TestUtils.player(fixture)
	runtime = TestUtils.start(fixture)
end)

afterEach(function()
	TestUtils.destroy(fixture)
	State.Stop()
end)

it(
	"counts anchored generations separately from completed sends, superseded generations and active ownership",
	function()
		local actor = TestUtils.actor(fixture, nil)
		TestUtils.ready(fixture, player)
		local first = assert(Diagnostics.GetConnectionSnapshot(player))
		expect(first.counters.baselinesCaptured).toBe(1)
		expect(first.counters.baselinesCompleted).toBe(0)
		expect(first.gauges.baselineGenerations.current).toBe(1)
		expect(first.gauges.awareStreams.current).toBe(1)
		expect(first.gauges.reliableActiveStreams.current).toBe(1)
		now = 103
		expect(assert(Diagnostics.GetServerSnapshot()).ages.reliableEligibleQueueAgeSeconds).toBe(3)
		TestUtils.associate(fixture, actor, player)
		local replaced = assert(Diagnostics.GetConnectionSnapshot(player))
		expect(replaced.counters.baselinesCaptured).toBe(2)
		expect(replaced.counters.baselinesRestarted).toBe(1)
		expect(replaced.counters.baselinesAbandoned).toBe(1)
		expect(replaced.gauges.baselineGenerations.current).toBe(1)
		now = 104
		TestUtils.drain(fixture)
		local completed = assert(Diagnostics.GetConnectionSnapshot(player))
		expect(completed.counters.baselinesCompleted).toBe(1)
		expect(completed.counters.baselinesAbandoned).toBe(1)
		expect(completed.gauges.baselineGenerations.current).toBe(0)
		expect(completed.gauges.reliableActiveStreams.current).toBe(0)
		expect(completed.ages.reliableEligibleQueueAgeSeconds).toBeNil()
		expect(completed.maxima.reliableQueueResidenceSeconds).toBe(4)
		expect(completed.counters.reliableConnectionVisits > 0).toBe(true)
		expect(completed.maxima.reliablePumpWorkUnits > 0).toBe(true)
		local visits = completed.counters.reliableConnectionVisits
		runtime:Step(32768, 128)
		expect(assert(Diagnostics.GetConnectionSnapshot(player)).counters.reliableConnectionVisits).toBe(visits)
		runtime:OnActorUnregistering(actor)
		TestUtils.drain(fixture)
		expect(assert(Diagnostics.GetConnectionSnapshot(player)).gauges.awareStreams.current).toBe(0)
	end
)

it(
	"counts coalescing and event barriers as accepted publication, and one discontinuity per overload transition",
	function()
		local actor = TestUtils.actor(fixture, nil)
		TestUtils.ready(fixture, player)
		TestUtils.drain(fixture)
		fixture.publicDomain.value = 11
		fixture.publicDomain.callbacks[actor]()
		fixture.publicDomain.value = 12
		fixture.publicDomain.callbacks[actor]()
		local coalesced = assert(Diagnostics.GetConnectionSnapshot(player))
		expect(coalesced.counters.publicationAdmitted).toBe(2)
		expect(coalesced.counters.stateCoalesces).toBe(1)
		expect(coalesced.gauges.publicationQueuedRecords.current).toBe(1)

		for value = 13, 17 do
			fixture.publicDomain.value = value
			fixture.publicDomain.callbacks[actor]({ { id = "Changed", payload = value } })
		end

		local overloaded = assert(Diagnostics.GetConnectionSnapshot(player))
		expect(overloaded.counters.semanticBarriers).toBe(4)
		expect(overloaded.counters.streamDiscontinuities).toBe(1)
		expect(overloaded.counters.publicationDropped).toBe(1)
		expect(overloaded.counters.publicationRecordsAbandoned).toBe(4)
		expect(overloaded.gauges.publicationQueuedRecords.current).toBe(0)
		expect(overloaded.gauges.publicationQueuedBytes.current).toBe(0)
		TestUtils.drain(fixture)
		expect(assert(Diagnostics.GetConnectionSnapshot(player)).counters.baselinesCompleted).toBe(2)
	end
)

it(
	"reports backoff as deferred recovery and cancels old lifetime gauges without scanning or debiting re-Ready work",
	function()
		local actor = TestUtils.actor(fixture, nil)
		TestUtils.ready(fixture, player)
		TestUtils.drain(fixture)

		local internal: any = runtime
		internal.backlog.limits.maxBytes = 1
		local accepted, reason = runtime:RequestReplacementBaseline(player, assert(runtime:GetHandle(player, actor)))
		expect(accepted).toBe(false)
		expect(reason).toBe("ActorBaselineCapacity")
		local owner = assert(State.FindConnection(player))
		expect(owner:Snapshot().counters.recoveryBackoffs).toBe(1)
		expect(owner:Snapshot().gauges.recoveryStreams.current).toBe(1)
		expect(owner:Snapshot().ages.reliableEligibleQueueAgeSeconds).toBeNil()
		TestUtils.close(fixture, player)
		expect(owner:Snapshot().counters.recoveryAbandoned).toBe(1)
		expect(owner:Snapshot().gauges.recoveryStreams.current).toBe(0)
		expect(owner:Snapshot().gauges.reliableActiveStreams.current).toBe(0)
		State.Close(player)
		internal.backlog.limits.maxBytes = 4096
		TestUtils.ready(fixture, player)
		local fresh = assert(State.FindConnection(player))
		expect(fresh:Snapshot().gauges.baselineGenerations.current).toBe(1)
		TestUtils.drain(fixture)
		expect(fresh:Snapshot().counters.baselinesCompleted).toBe(1)
		expect(owner:Snapshot().gauges.recoveryStreams.current).toBe(0)
	end
)

it("counts a superseded generation even when capture reuses the exact same admitted baseline charge", function()
	local actor = TestUtils.actor(fixture, nil)
	TestUtils.ready(fixture, player)
	local internal: any = runtime
	local stream = internal.connections[player].actors[actor]
	local charge = stream.baseline.charge
	expect(stream:Capture()).toBe(true)
	expect(stream.baseline.charge).toBe(charge)
	local replaced = assert(Diagnostics.GetConnectionSnapshot(player))
	expect(replaced.counters.baselinesCaptured).toBe(2)
	expect(replaced.counters.baselinesRestarted).toBe(1)
	expect(replaced.counters.baselinesAbandoned).toBe(1)
	expect(replaced.gauges.baselineGenerations.current).toBe(1)
	expect(replaced.gauges.reliableRecords.current).toBe(1)
	TestUtils.drain(fixture)
	local completed = assert(Diagnostics.GetConnectionSnapshot(player))
	expect(completed.counters.baselinesCompleted).toBe(1)
	expect(completed.gauges.baselineGenerations.current).toBe(0)
	expect(completed.gauges.reliableRecords.current).toBe(0)
end)
