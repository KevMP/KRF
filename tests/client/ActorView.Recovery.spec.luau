--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local PublicTypes = require(KRF.client.Actor.types)
local ClientNetworkingTypes = require(KRF.client.Networking.types)
local SignalTypes = require(KRF.shared.Signal.types)
local ResyncCodec = require(KRF.shared.Networking.utils.ResyncCodec)
local TestUtils = require(script.Parent.Utils.ActorViewTestUtils)

local fixture: TestUtils.Fixture
beforeEach(function()
	fixture = TestUtils.new()
end)
afterEach(function()
	TestUtils.destroy(fixture)
end)

it("accepts exactly R+1 and preserves the ActorView and its DomainViews", function()
	TestUtils.baseline(fixture)
	local view: PublicTypes.ActorView = TestUtils.view(fixture)
	local domain: PublicTypes.DomainView = TestUtils.domain(fixture)
	TestUtils.commit(fixture, 11, { TestUtils.patch(75) })
	TestUtils.commit(fixture, 12, { TestUtils.patch(50) })
	expect(TestUtils.view(fixture)).toBe(view)
	expect(TestUtils.domain(fixture)).toBe(domain)
	expect(domain:GetState().current).toBe(50)
	expect(fixture.requests).toEqual({})
end)

for _, revision: number in { 9, 10, 12, 1000 } do
	it(
		"keeps last valid truth and sends one private Reliable resync when expected 11 but received "
			.. tostring(revision),
		function()
			TestUtils.baseline(fixture)
			local view: PublicTypes.ActorView = TestUtils.view(fixture)
			local state: any = TestUtils.domain(fixture):GetState()
			TestUtils.commit(fixture, revision, { TestUtils.patch(5) })
			expect(TestUtils.view(fixture)).toBe(view)
			expect(TestUtils.domain(fixture):GetState()).toBe(state)
			local diagnostics: ClientNetworkingTypes.ActorViewDiagnostics? = fixture.runtime:_InspectForTests(1)
			assert(diagnostics ~= nil, "Expected private recovery diagnostics")
			expect(diagnostics.revision).toBe(10)
			expect(diagnostics.status).toBe("AwaitingBaseline")
			expect(#fixture.requests).toBe(1)
			expect(typeof(fixture.requests[1])).toBe("buffer")
			local request: ResyncCodec.Request?, reason: string? = ResyncCodec.Decode(fixture.requests[1])
			expect(reason).toBeNil()
			expect(request).toEqual({ handle = 1 })
			expect(#fixture.faults).toBe(1)
			expect(fixture.faults[1].actorId).toBe("ActorA")
		end
	)
end

it("rejects a duplicate of the last successful live revision", function()
	TestUtils.baseline(fixture)
	TestUtils.commit(fixture, 11, { TestUtils.patch(75) })
	TestUtils.commit(fixture, 11, { TestUtils.patch(5) })
	expect(TestUtils.domain(fixture):GetState().current).toBe(75)
	expect(#fixture.requests).toBe(1)
end)

it("drops all incremental work while awaiting baseline without a growing history or request storm", function()
	TestUtils.baseline(fixture)
	local state: any = TestUtils.domain(fixture):GetState()
	local changed: number = 0
	table.insert(
		fixture.connections,
		TestUtils.domain(fixture).OnChanged:Connect(function(_change: PublicTypes.DomainChange)
			changed += 1
		end)
	)
	TestUtils.commit(fixture, 12, { TestUtils.patch(1) })
	for revision: number = 11, 266 do
		TestUtils.commit(
			fixture,
			revision,
			{ TestUtils.patch(2) },
			{ { domainId = "Game.Counter", eventId = "Changed", payload = revision } }
		)
	end
	expect(TestUtils.domain(fixture):GetState()).toBe(state)
	expect(changed).toBe(0)
	expect(#fixture.requests).toBe(1)
	local diagnostics: ClientNetworkingTypes.ActorViewDiagnostics? = fixture.runtime:_InspectForTests(1)
	assert(diagnostics ~= nil, "Expected recovery diagnostics")
	expect(diagnostics.bufferedCommitCount).toBe(0)
	expect(diagnostics.revision).toBe(10)
	TestUtils.baseline(fixture, 1, nil, 300, TestUtils.truth(40), 2)
	expect(TestUtils.domain(fixture):GetState().current).toBe(40)
	TestUtils.commit(fixture, 301, { TestUtils.patch(35) })
	expect(TestUtils.domain(fixture):GetState().current).toBe(35)
	expect(changed).toBe(2)
end)

it("isolates recovery by Actor while another Actor continues revisions and semantic dispatch", function()
	TestUtils.baseline(fixture)
	TestUtils.baseline(fixture, 2, "ActorB")
	local other: PublicTypes.ActorView = TestUtils.view(fixture, "ActorB")
	local payloads: { number } = {}
	local event: SignalTypes.Event<any>? = TestUtils.domain(fixture, "Game.Counter", "ActorB"):GetEvent("Changed")
	assert(event ~= nil, "Expected declared counter event")
	table.insert(
		fixture.connections,
		event:Connect(function(payload: number)
			table.insert(payloads, payload)
		end)
	)
	TestUtils.commit(fixture, 12, { TestUtils.patch(5) })
	TestUtils.commit(
		fixture,
		11,
		{ TestUtils.patch(60) },
		{ { domainId = "Game.Counter", eventId = "Changed", payload = 11 } },
		2
	)
	expect(TestUtils.view(fixture, "ActorB")).toBe(other)
	expect(TestUtils.domain(fixture, nil, "ActorB"):GetState().current).toBe(60)
	expect(payloads).toEqual({ 11 })
	expect(TestUtils.domain(fixture):GetState().current).toBe(100)
	expect(#fixture.requests).toBe(1)
end)

it("starts a fresh single-request recovery episode after successful replacement", function()
	TestUtils.baseline(fixture)
	TestUtils.commit(fixture, 12)
	TestUtils.baseline(fixture, 1, nil, 50, TestUtils.truth(50), 2)
	TestUtils.commit(fixture, 52)
	TestUtils.commit(fixture, 53)
	expect(#fixture.requests).toBe(2)
	expect(TestUtils.domain(fixture):GetState().current).toBe(50)
end)

for _, revision: number in { -1, 0 / 0, math.huge, 10.5, 4294967296 } do
	it("faults an invalid decoded revision " .. tostring(revision) .. " before applying state", function()
		TestUtils.baseline(fixture)
		local state: any = TestUtils.domain(fixture):GetState()
		fixture.runtime.consumer.OnCommitReady(TestUtils.actor(fixture), revision, { TestUtils.patch(1) }, {})
		expect(TestUtils.domain(fixture):GetState()).toBe(state)
		expect(#fixture.requests).toBe(1)
	end)
end

it("never wraps the maximum private revision to zero", function()
	TestUtils.baseline(fixture, nil, nil, 4294967294)
	TestUtils.commit(fixture, 4294967295, { TestUtils.patch(75) })
	fixture.runtime.consumer.OnCommitReady(TestUtils.actor(fixture), 0, { TestUtils.patch(1) }, {})
	expect(TestUtils.domain(fixture):GetState().current).toBe(75)
	expect(#fixture.requests).toBe(1)
end)

it("keeps a failed resync send observable and bounded without throwing out of the receive path", function()
	TestUtils.destroy(fixture)
	fixture = TestUtils.new(function(_payload: buffer)
		error("ForcedResyncSendFailure", 0)
	end)
	TestUtils.baseline(fixture)
	local previous: any = TestUtils.domain(fixture):GetState()
	TestUtils.commit(fixture, 12)
	TestUtils.commit(fixture, 13)
	TestUtils.commit(fixture, 14)
	expect(TestUtils.domain(fixture):GetState()).toBe(previous)
	expect(#fixture.requests).toBe(1)
	expect(#fixture.faults > 0).toBe(true)
	local diagnostics: ClientNetworkingTypes.ActorViewDiagnostics? = fixture.runtime:_InspectForTests(1)
	assert(diagnostics ~= nil, "Expected observable failed recovery")
	expect(diagnostics.status).never.toBe("Live")
end)
