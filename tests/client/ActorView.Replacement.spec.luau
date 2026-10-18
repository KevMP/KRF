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

beforeEach(function()
	fixture = TestUtils.new()
end)

afterEach(function()
	GoodSignal.Fire = originalFire
	TestUtils.destroy(fixture)
end)

it(
	"atomically replaces truth at a jumping revision while preserving view identity and existing subscriptions",
	function()
		TestUtils.baseline(fixture)
		local view: PublicTypes.ActorView = TestUtils.view(fixture)
		local domain: PublicTypes.DomainView = TestUtils.domain(fixture)
		local previous: any = domain:GetState()
		local changes: { PublicTypes.DomainChange } = {}

		table.insert(
			fixture.connections,
			domain.OnChanged:Connect(function(change: PublicTypes.DomainChange)
				table.insert(changes, change)
			end)
		)

		TestUtils.commit(fixture, 12)
		TestUtils.baseline(fixture, 1, nil, 70, TestUtils.truth(25), 2)
		expect(TestUtils.view(fixture)).toBe(view)
		expect(TestUtils.domain(fixture)).toBe(domain)
		expect(#changes).toBe(1)

		expect(changes[1]).toEqual({
			previous = previous,
			current = TestUtils.truth(25)["Game.Stamina"].value,
			source = "Baseline",
		})

		expect(previous.current).toBe(100)
		expect(table.isfrozen(changes[1].current.effects.Burn)).toBe(true)
		TestUtils.commit(fixture, 71, { TestUtils.patch(20) })
		expect(domain:GetState().current).toBe(20)
		expect(changes[2].source).toBe("Commit")
		expect(#fixture.requests).toBe(1)
		local diagnostics: ClientNetworkingTypes.ActorViewDiagnostics? = fixture.runtime:_InspectForTests(1)
		assert(diagnostics ~= nil, "Expected installed replacement revision")
		expect(diagnostics.revision).toBe(71)
		expect(diagnostics.status).toBe("Live")
	end
)

it("accepts a server-initiated replacement during Live without a client recovery request", function()
	TestUtils.baseline(fixture)
	local view: PublicTypes.ActorView = TestUtils.view(fixture)
	TestUtils.baseline(fixture, 1, nil, 80, TestUtils.truth(60), 2)
	expect(TestUtils.view(fixture)).toBe(view)
	expect(TestUtils.domain(fixture):GetState().current).toBe(60)
	TestUtils.commit(fixture, 81, { TestUtils.patch(55) })
	expect(TestUtils.domain(fixture):GetState().current).toBe(55)
	expect(fixture.requests).toEqual({})
end)

it("suppresses equal replacement notifications, semantic history and registry Added events", function()
	TestUtils.baseline(fixture)
	TestUtils.view(fixture)
	local fires: { any } = {}

	GoodSignal.Fire = function(self: any, ...: any)
		table.insert(fires, table.pack(...))
		originalFire(self, ...)
	end

	TestUtils.baseline(fixture, 1, nil, 50, TestUtils.truth(), 2)
	expect(fires).toEqual({})
	TestUtils.baseline(fixture, 1, nil, 60, TestUtils.truth(40), 3)
	expect(#fires).toBe(1)
	expect(fires[1][1].source).toBe("Baseline")
end)

it("keeps the previous domain set and truth public until the replacement completely arrives", function()
	TestUtils.baseline(fixture)
	local view: PublicTypes.ActorView = TestUtils.view(fixture)
	local owner: PublicTypes.DomainView = TestUtils.domain(fixture, "Game.Owner")

	local replacement: { [string]: SharedNetworkingTypes.ActorDomainTruth } = TestUtils.truth(30)
	replacement["Game.Owner"] = nil
	local body: buffer?, reason: string? = fixture.stream.codec.EncodeBaseline(replacement)
	assert(body ~= nil, reason)
	TestUtils.send(fixture, { { kind = "BaselineBegin", handle = 1, generation = 2, totalBytes = buffer.len(body) } })
	local length: number = math.floor(buffer.len(body) / 2)
	local first: buffer = buffer.create(length)
	buffer.copy(first, 0, body, 0, length)
	TestUtils.send(fixture, { { kind = "BaselineChunk", handle = 1, generation = 2, offset = 0, bytes = first } })
	expect(view:GetDomain("Game.Owner")).toBe(owner)
	expect(TestUtils.domain(fixture):GetState().current).toBe(100)
	local rest: buffer = buffer.create(buffer.len(body) - length)
	buffer.copy(rest, 0, body, length)

	TestUtils.send(fixture, {
		{ kind = "BaselineChunk", handle = 1, generation = 2, offset = length, bytes = rest },
		{ kind = "BaselineEnd", handle = 1, generation = 2, revision = 50 },
	})

	expect(view:GetDomain("Game.Owner")).toBeNil()
	expect(TestUtils.domain(fixture):GetState().current).toBe(30)
end)

it("reconciles Owner visibility loss atomically before any Baseline Fire and retires held private state", function()
	TestUtils.baseline(fixture)
	local view: PublicTypes.ActorView = TestUtils.view(fixture)
	local owner: PublicTypes.DomainView = TestUtils.domain(fixture, "Game.Owner")
	local visibleAtFire: { { string } } = {}
	local visibleAtMembershipFire: { { string } } = {}

	GoodSignal.Fire = function(self: any, ...: any)
		local payload: any = ...

		if payload.source == "Baseline" then
			table.insert(visibleAtFire, view:GetDomainIds())
		else
			table.insert(visibleAtMembershipFire, view:GetDomainIds())
		end

		originalFire(self, ...)
	end

	local replacement: { [string]: SharedNetworkingTypes.ActorDomainTruth } = TestUtils.truth(30)
	replacement["Game.Owner"] = nil
	TestUtils.baseline(fixture, 1, nil, 50, replacement, 2)
	expect(view:GetDomain("Game.Owner")).toBeNil()
	expect(view:GetDomainIds()).toEqual({ "Game.Counter", "Game.Stamina" })
	expect(visibleAtFire).toEqual({ { "Game.Counter", "Game.Stamina" } })
	expect(visibleAtMembershipFire).toEqual({ { "Game.Counter", "Game.Stamina" } })

	local readable: boolean, state: any = pcall(function(): any
		return owner:GetState()
	end)

	if readable then
		expect(state).toBeNil()
	end

	TestUtils.baseline(fixture, 1, nil, 60, TestUtils.truth(20), 3)
	local restored: PublicTypes.DomainView = TestUtils.domain(fixture, "Game.Owner")
	expect(restored).never.toBe(owner)
	expect(restored:GetState()).toEqual({ secret = "owner-only" })
end)

it("adds a newly visible domain and every new value before notifying a retained domain", function()
	local initial: { [string]: SharedNetworkingTypes.ActorDomainTruth } = TestUtils.truth()
	initial["Game.Owner"] = nil
	TestUtils.baseline(fixture, nil, nil, nil, initial)
	local view: PublicTypes.ActorView = TestUtils.view(fixture)
	local observed: { any } = {}

	table.insert(
		fixture.connections,
		TestUtils.domain(fixture).OnChanged:Connect(function(_change: PublicTypes.DomainChange)
			local owner: PublicTypes.DomainView? = view:GetDomain("Game.Owner")

			table.insert(
				observed,
				{ ids = view:GetDomainIds(), owner = if owner ~= nil then owner:GetState() else nil }
			)
		end)
	)

	TestUtils.baseline(fixture, 1, nil, 50, TestUtils.truth(30), 2)

	expect(observed).toEqual({
		{ ids = { "Game.Counter", "Game.Owner", "Game.Stamina" }, owner = { secret = "owner-only" } },
	})
end)

it("reconciles replacement to an empty visible domain set", function()
	TestUtils.baseline(fixture)
	local view: PublicTypes.ActorView = TestUtils.view(fixture)
	local domain: PublicTypes.DomainView = TestUtils.domain(fixture)
	TestUtils.baseline(fixture, 1, nil, 50, {}, 2)
	expect(TestUtils.view(fixture)).toBe(view)
	expect(view:GetDomainIds()).toEqual({})
	expect(view:GetDomain("Game.Stamina")).toBeNil()

	local readable: boolean, state: any = pcall(function(): any
		return domain:GetState()
	end)

	if readable then
		expect(state).toBeNil()
	end
end)

it("rolls back values and visibility together when a decoded replacement contains one invalid domain", function()
	TestUtils.baseline(fixture)
	local view: PublicTypes.ActorView = TestUtils.view(fixture)
	local owner: PublicTypes.DomainView = TestUtils.domain(fixture, "Game.Owner")
	local previous: any = TestUtils.domain(fixture):GetState()
	local fires: number = 0

	GoodSignal.Fire = function(self: any, ...: any)
		fires += 1
		originalFire(self, ...)
	end

	local invalid: { [string]: SharedNetworkingTypes.ActorDomainTruth } = TestUtils.truth(30)
	invalid["Game.Owner"] = nil
	invalid["Game.Counter"] = { value = "invalid" }
	fixture.runtime.consumer.OnBaselineReady(TestUtils.actor(fixture), 50, invalid)
	expect(TestUtils.domain(fixture):GetState()).toBe(previous)
	expect(view:GetDomain("Game.Owner")).toBe(owner)
	expect(owner:GetState()).toEqual({ secret = "owner-only" })
	local diagnostics: ClientNetworkingTypes.ActorViewDiagnostics? = fixture.runtime:_InspectForTests(1)
	assert(diagnostics ~= nil, "Expected preserved revision")
	expect(diagnostics.revision).toBe(10)
	expect(diagnostics.status).toBe("AwaitingBaseline")
	expect(#fixture.faults).toBe(1)
	expect(fires).toBe(0)
end)

it("destroys removed DomainView subscriptions without reviving them when the domain returns", function()
	TestUtils.baseline(fixture)
	local domain: PublicTypes.DomainView = TestUtils.domain(fixture)
	local event = domain:GetEvent("Depleted")
	assert(event ~= nil, "Expected declared event")
	local calls: number = 0

	table.insert(
		fixture.connections,
		event:Connect(function(_payload: any)
			calls += 1
		end)
	)

	local replacement: { [string]: SharedNetworkingTypes.ActorDomainTruth } = TestUtils.truth()
	replacement["Game.Stamina"] = nil
	TestUtils.baseline(fixture, 1, nil, 50, replacement, 2)

	local connectedEvent: boolean = pcall(function()
		event:Connect(function(_payload: any) end)
	end)

	expect(connectedEvent).toBe(false)

	local connectedChange: boolean = pcall(function()
		domain.OnChanged:Connect(function(_change: PublicTypes.DomainChange) end)
	end)

	expect(connectedChange).toBe(false)
	TestUtils.baseline(fixture, 1, nil, 60, TestUtils.truth(), 3)

	TestUtils.commit(
		fixture,
		61,
		{},
		{ { domainId = "Game.Stamina", eventId = "Depleted", payload = { previous = 100 } } }
	)

	expect(TestUtils.domain(fixture)).never.toBe(domain)
	expect(calls).toBe(0)
end)

it("keeps the last good truth and reports repeated invalid recovery data without recursive retry traffic", function()
	TestUtils.baseline(fixture)
	local previous: any = TestUtils.domain(fixture):GetState()
	TestUtils.commit(fixture, 12)

	for _ = 1, 32 do
		fixture.runtime.consumer.OnBaselineReady(TestUtils.actor(fixture), 50, { ["Unknown"] = { value = 1 } })
	end

	expect(TestUtils.domain(fixture):GetState()).toBe(previous)
	expect(#fixture.requests).toBe(1)
	expect(#fixture.faults > 0).toBe(true)
	local diagnostics: ClientNetworkingTypes.ActorViewDiagnostics? = fixture.runtime:_InspectForTests(1)
	assert(diagnostics ~= nil, "Expected observable recovery state")
	expect(diagnostics.status).never.toBe("Live")
	expect(diagnostics.revision).toBe(10)
end)
