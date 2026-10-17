--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local PublicTypes = require(KRF.client.Actor.types)
local SharedNetworkingTypes = require(KRF.shared.Networking.types)
local ClientNetworkingTypes = require(KRF.client.Networking.types)
local TestUtils = require(script.Parent.Utils.ActorViewTestUtils)
local StreamUtils = require(script.Parent.Utils.ActorStreamTestUtils)

local fixture: TestUtils.Fixture
beforeEach(function()
	fixture = TestUtils.new()
end)
afterEach(function()
	TestUtils.destroy(fixture)
end)

it("publishes nothing until the complete initial baseline ends, then publishes every visible domain once", function()
	local candidate: ClientNetworkingTypes.ActorModelCandidate = StreamUtils.candidate(fixture.stream, "ActorA")
	StreamUtils.add(fixture.stream, candidate)
	local added: { PublicTypes.ActorView } = {}
	local observed: { any } = {}
	table.insert(
		fixture.connections,
		fixture.runtime.registry.OnActorViewAdded:Connect(function(view: PublicTypes.ActorView)
			table.insert(added, view)
			table.insert(observed, {
				id = view:GetId(),
				model = view:GetModel(),
				domains = view:GetDomainIds(),
				state = (view:GetDomain("Game.Stamina") :: PublicTypes.DomainView):GetState(),
			})
		end)
	)
	local truth: { [string]: SharedNetworkingTypes.ActorDomainTruth } = TestUtils.truth()
	local body: buffer?, reason: string? = fixture.stream.codec.EncodeBaseline(truth)
	assert(body ~= nil, reason)
	TestUtils.send(
		fixture,
		{ { kind = "BaselineBegin", handle = 1, actorId = "ActorA", generation = 1, totalBytes = buffer.len(body) } }
	)
	expect(fixture.runtime.registry.GetAllActorViews()).toEqual({})
	expect(fixture.runtime.registry.GetActorViewByModel(candidate.model)).toBeNil()
	TestUtils.send(fixture, { { kind = "BaselineChunk", handle = 1, generation = 1, offset = 0, bytes = body } })
	expect(fixture.runtime.registry.GetActorViewById("ActorA")).toBeNil()
	expect(added).toEqual({})
	TestUtils.send(fixture, { { kind = "BaselineEnd", handle = 1, generation = 1, revision = 10 } })
	local view: PublicTypes.ActorView = TestUtils.view(fixture)
	expect(added).toEqual({ view })
	expect(observed).toEqual({
		{
			id = "ActorA",
			model = candidate.model,
			domains = { "Game.Counter", "Game.Owner", "Game.Stamina" },
			state = truth["Game.Stamina"].value,
		},
	})
	expect(fixture.runtime.registry.GetActorViewByModel(candidate.model)).toBe(view)
	for id: string, domain: SharedNetworkingTypes.ActorDomainTruth in truth do
		expect(TestUtils.domain(fixture, id):GetState()).toEqual(domain.value)
	end
end)

it("creates a Model-independent view and distinguishes absent domains from Optional nil truth", function()
	TestUtils.baseline(fixture, nil, nil, nil, { ["Game.Owner"] = { value = nil } })
	local view: PublicTypes.ActorView = TestUtils.view(fixture)
	expect(view:GetModel()).toBeNil()
	expect(view:GetDomainIds()).toEqual({ "Game.Owner" })
	expect(TestUtils.domain(fixture, "Game.Owner"):GetState()).toBeNil()
	expect(view:GetDomain("Game.Stamina")).toBeNil()
	expect(view:GetDomain("Unknown")).toBeNil()
end)

it("supports an empty visible domain set without manufacturing domain definitions", function()
	TestUtils.baseline(fixture, nil, nil, nil, {})
	expect(TestUtils.view(fixture):GetDomainIds()).toEqual({})
end)

it("returns independent registry and domain-id collections", function()
	TestUtils.baseline(fixture)
	TestUtils.baseline(fixture, 2, "ActorB")
	local first: PublicTypes.ActorView = TestUtils.view(fixture)
	local second: PublicTypes.ActorView = TestUtils.view(fixture, "ActorB")
	local all: { PublicTypes.ActorView } = fixture.runtime.registry.GetAllActorViews()
	expect(#all).toBe(2)
	expect(all).toContain(first)
	expect(all).toContain(second)
	pcall(table.clear, all)
	pcall(table.clear, first:GetDomainIds())
	expect(#fixture.runtime.registry.GetAllActorViews()).toBe(2)
	expect(first:GetDomainIds()).toEqual({ "Game.Counter", "Game.Owner", "Game.Stamina" })
	expect(fixture.runtime.registry.GetActorViewById("Unknown")).toBeNil()
end)

it("rejects a second handle claiming an existing actorId without overwriting current truth", function()
	TestUtils.baseline(fixture)
	local view: PublicTypes.ActorView = TestUtils.view(fixture)
	local accepted: boolean, reason: string? = StreamUtils.send(
		fixture.stream,
		{ { kind = "BaselineBegin", handle = 2, actorId = "ActorA", generation = 1, totalBytes = 1 } }
	)
	expect(accepted).toBe(false)
	expect(reason).toBe("ActorIdConflict")
	expect(TestUtils.view(fixture)).toBe(view)
	expect(TestUtils.domain(fixture):GetState().current).toBe(100)
	expect(#fixture.runtime.registry.GetAllActorViews()).toBe(1)
end)

it("rejects a conflicting decoded identity even if a caller bypasses the N4 identity guard", function()
	TestUtils.baseline(fixture)
	local view: PublicTypes.ActorView = TestUtils.view(fixture)
	fixture.runtime.consumer.OnBaselineReady({ actorId = "ActorA", handle = 2, model = nil }, 10, TestUtils.truth(5))
	expect(TestUtils.view(fixture)).toBe(view)
	expect(TestUtils.domain(fixture):GetState().current).toBe(100)
	expect(#fixture.faults).toBe(1)
	expect(fixture.faults[1].actorId).toBe("ActorA")
end)

for _, invalid: { [string]: SharedNetworkingTypes.ActorDomainTruth } in
	{
		{ ["Game.Stamina"] = { value = { current = 100 } } },
		{ ["Unknown"] = { value = 1 } },
	}
do
	it("rejects an invalid decoded initial baseline without a partial public view", function()
		fixture.runtime.consumer.OnBaselineReady({ actorId = "ActorA", handle = 1, model = nil }, 10, invalid)
		expect(fixture.runtime.registry.GetAllActorViews()).toEqual({})
		expect(#fixture.faults).toBe(1)
		expect(fixture.faults[1].actorId).toBe("ActorA")
	end)
end
