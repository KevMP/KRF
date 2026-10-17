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
local SharedNetworkingTypes = require(KRF.shared.Networking.types)
local GoodSignal: any = require(KRF.shared.Signal.GoodSignal)
local TestUtils = require(script.Parent.Utils.ActorViewTestUtils)

local fixture: TestUtils.Fixture
local originalFire: any = GoodSignal.Fire
local fires: { any }
beforeEach(function()
	fixture = TestUtils.new()
	fires = {}
	-- Observe Fire invocations rather than infer their order from scheduled handlers.
	GoodSignal.Fire = function(self: any, ...: any)
		local view: PublicTypes.ActorView? = fixture.runtime.registry.GetActorViewById("ActorA")
		local stamina: PublicTypes.DomainView? = if view ~= nil then view:GetDomain("Game.Stamina") else nil
		local counter: PublicTypes.DomainView? = if view ~= nil then view:GetDomain("Game.Counter") else nil
		local diagnostics: ClientNetworkingTypes.ActorViewDiagnostics? = fixture.runtime:_InspectForTests(1)
		table.insert(fires, {
			args = table.pack(...),
			stamina = if stamina ~= nil then stamina:GetState() else nil,
			counter = if counter ~= nil then counter:GetState() else nil,
			revision = if diagnostics ~= nil then diagnostics.revision else nil,
		})
		originalFire(self, ...)
	end
end)
afterEach(function()
	GoodSignal.Fire = originalFire
	TestUtils.destroy(fixture)
end)

it("fires only Added on initial publication without synthesizing domain changes or semantic history", function()
	TestUtils.baseline(fixture)
	local view: PublicTypes.ActorView = TestUtils.view(fixture)
	expect(#fires).toBe(1)
	expect(fires[1].args[1]).toBe(view)
	expect(fires[1].stamina.current).toBe(100)
	expect(fires[1].counter).toBe(7)
end)

it(
	"installs all domains and the revision before any change Fire, then fires semantic events in supplied order",
	function()
		TestUtils.baseline(fixture)
		TestUtils.view(fixture)
		fires = {}
		TestUtils.commit(fixture, 11, {
			TestUtils.patch(75),
			{ domainId = "Game.Counter", patch = { kind = "Replace", value = 8 } },
		}, {
			{ domainId = "Game.Stamina", eventId = "Depleted", payload = { previous = 100 } },
			{ domainId = "Game.Counter", eventId = "Changed", payload = 8 },
			{ domainId = "Game.Stamina", eventId = "Changed", payload = { amount = 25, history = { 100, 75 } } },
		})
		expect(#fires).toBe(5)
		for index: number, fired: any in fires do
			expect(fired.stamina.current).toBe(75)
			expect(fired.counter).toBe(8)
			expect(fired.revision).toBe(11)
			if index <= 2 then
				expect(fired.args[1].source).toBe("Commit")
			end
		end
		expect(fires[3].args[1]).toEqual({ previous = 100 })
		expect(fires[4].args[1]).toBe(8)
		expect(fires[5].args[1]).toEqual({ amount = 25, history = { 100, 75 } })
		local diagnostics: ClientNetworkingTypes.ActorViewDiagnostics? = fixture.runtime:_InspectForTests(1)
		assert(diagnostics ~= nil, "Expected private revision diagnostics")
		expect(diagnostics.revision).toBe(11)
		-- Changed-domain dispatch uses deterministic domain-id order.
		expect(fires[1].args[1].current).toBe(8)
		expect(fires[2].args[1].current.current).toBe(75)
	end
)

it("advances event-only and state-identical revisions without OnChanged and preserves order across commits", function()
	TestUtils.baseline(fixture)
	TestUtils.view(fixture)
	fires = {}
	TestUtils.commit(fixture, 11, {}, { { domainId = "Game.Counter", eventId = "Changed", payload = 11 } })
	TestUtils.commit(
		fixture,
		12,
		{ TestUtils.patch(100) },
		{ { domainId = "Game.Counter", eventId = "Changed", payload = 12 } }
	)
	TestUtils.commit(fixture, 13, {})
	expect(#fires).toBe(2)
	expect(fires[1].args[1]).toBe(11)
	expect(fires[2].args[1]).toBe(12)
	TestUtils.commit(fixture, 14, { TestUtils.patch(75) })
	expect(TestUtils.domain(fixture):GetState().current).toBe(75)
	expect(#fixture.requests).toBe(0)
end)

type BadCommit = {
	name: string,
	patches: { SharedNetworkingTypes.ActorDomainPatch },
	events: { SharedNetworkingTypes.ActorEvent },
}
local badCommits: { BadCommit } = {
	{
		name = "invalid second domain patch",
		patches = { TestUtils.patch(50), { domainId = "Game.Counter", patch = { kind = "Replace", value = -1 } } },
		events = { { domainId = "Game.Counter", eventId = "Changed", payload = 1 } },
	},
	{
		name = "unknown domain",
		patches = { TestUtils.patch(50), { domainId = "Unknown", patch = { kind = "Replace", value = 1 } } },
		events = {},
	},
	{
		name = "unknown event",
		patches = { TestUtils.patch(50) },
		events = { { domainId = "Game.Stamina", eventId = "Unknown", payload = {} } },
	},
	{
		name = "invalid event payload",
		patches = { TestUtils.patch(50) },
		events = { { domainId = "Game.Counter", eventId = "Changed", payload = "bad" } },
	},
	{
		name = "malformed Struct patch",
		patches = {
			{
				domainId = "Game.Stamina",
				patch = { kind = "Struct", fields = { missing = { kind = "Replace", value = 1 } } },
			},
		},
		events = {},
	},
	{ name = "duplicate domain patches", patches = { TestUtils.patch(50), TestUtils.patch(25) }, events = {} },
}
for _, case: BadCommit in badCommits do
	it(
		"publishes no part of a commit with " .. case.name .. " and requests recovery from the unchanged revision",
		function()
			TestUtils.baseline(fixture)
			local previous: any = TestUtils.domain(fixture):GetState()
			fires = {}
			fixture.runtime.consumer.OnCommitReady(TestUtils.actor(fixture), 11, case.patches, case.events)
			expect(TestUtils.domain(fixture):GetState()).toBe(previous)
			expect(TestUtils.domain(fixture, "Game.Counter"):GetState()).toBe(7)
			expect(fires).toEqual({})
			local diagnostics: ClientNetworkingTypes.ActorViewDiagnostics? = fixture.runtime:_InspectForTests(1)
			assert(diagnostics ~= nil, "Expected unchanged revision diagnostics")
			expect(diagnostics.revision).toBe(10)
			expect(diagnostics.status).toBe("AwaitingBaseline")
			expect(#fixture.requests).toBe(1)
			expect(#fixture.faults).toBe(1)
		end
	)
end

it("rejects a bootstrap-known but currently invisible domain without making it visible", function()
	local truth: { [string]: SharedNetworkingTypes.ActorDomainTruth } = TestUtils.truth()
	truth["Game.Owner"] = nil
	TestUtils.baseline(fixture, nil, nil, nil, truth)
	TestUtils.view(fixture)
	fixture.runtime.consumer.OnCommitReady(
		TestUtils.actor(fixture),
		11,
		{ { domainId = "Game.Owner", patch = { kind = "Replace", value = { secret = "leaked" } } } },
		{}
	)
	expect(TestUtils.view(fixture):GetDomain("Game.Owner")).toBeNil()
	expect(#fixture.requests).toBe(1)
end)
