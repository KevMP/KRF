--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local Types = require(KRF.client.Networking.types)
local PublicTypes = require(KRF.client.Actor.types)
local TestUtils = require(script.Parent.Utils.ActorViewTestUtils)
local StreamUtils = require(script.Parent.Utils.ActorStreamTestUtils)

local fixture: TestUtils.Fixture

beforeEach(function()
	fixture = TestUtils.new()
end)

afterEach(function()
	TestUtils.destroy(fixture)
end)

it("rejects an invalid initial revision before publication and admits a later complete baseline", function()
	local actor: Types.ActorStreamRecord = { handle = 1, actorId = "ActorA", model = nil }
	fixture.runtime.consumer.OnBaselineReady(actor, -1, TestUtils.truth())
	expect(fixture.runtime.registry.GetAllActorViews()).toEqual({})
	expect(#fixture.requests).toBe(1)
	expect(fixture.faults).toEqual({ { actorId = "ActorA", reason = "InvalidActorRevision" } })
	fixture.runtime.consumer.OnBaselineReady(actor, 30, TestUtils.truth(70))
	fixture.runtime.consumer.OnCommitReady(actor, 31, { TestUtils.patch(60) }, {})
	expect(TestUtils.domain(fixture):GetState().current).toBe(60)
end)

it("contains malformed decoded baseline and commit containers without publishing partial state", function()
	TestUtils.baseline(fixture)
	local actor: Types.ActorStreamRecord = TestUtils.actor(fixture)
	local view: PublicTypes.ActorView = TestUtils.view(fixture)
	fixture.runtime.consumer.OnBaselineReady(actor, 50, false :: any)
	expect(TestUtils.domain(fixture):GetState().current).toBe(100)
	expect(#fixture.requests).toBe(1)
	fixture.runtime.consumer.OnBaselineReady(actor, 50, TestUtils.truth(70))
	fixture.runtime.consumer.OnCommitReady(actor, 51, { false } :: any, {})
	expect(TestUtils.domain(fixture):GetState().current).toBe(70)
	expect(TestUtils.view(fixture)).toBe(view)
	expect(#fixture.requests).toBe(2)
	expect(#fixture.faults).toBe(2)
	fixture.runtime.consumer.OnBaselineReady(actor, 60, TestUtils.truth(50))
	fixture.runtime.consumer.OnCommitReady(actor, 61, {} :: any, false :: any)
	expect(TestUtils.domain(fixture):GetState().current).toBe(50)
	expect(#fixture.requests).toBe(3)
end)

it("rejects a foreign decoded record claiming an active handle without stealing its identity", function()
	TestUtils.baseline(fixture)
	local first: PublicTypes.ActorView = TestUtils.view(fixture)
	fixture.runtime.consumer.OnBaselineReady({ actorId = "ActorB", handle = 1, model = nil }, 50, TestUtils.truth(1))
	expect(fixture.runtime.registry.GetActorViewById("ActorB")).toBeNil()
	expect(TestUtils.view(fixture)).toBe(first)
	expect(TestUtils.domain(fixture):GetState().current).toBe(100)
	expect(fixture.faults).toEqual({ { actorId = "ActorB", reason = "ActorHandleConflict" } })
end)

it("ignores redundant Model binding and stale unbind callbacks without losing the indexed Model", function()
	local candidate: Types.ActorModelCandidate = StreamUtils.candidate(fixture.stream, "ActorA")
	StreamUtils.add(fixture.stream, candidate)
	TestUtils.baseline(fixture)
	local actor: Types.ActorStreamRecord = TestUtils.actor(fixture)
	local view: PublicTypes.ActorView = TestUtils.view(fixture)
	local changes: number = 0

	table.insert(
		fixture.connections,
		view.OnModelChanged:Connect(function(_previous: Model?, _current: Model?)
			changes += 1
		end)
	)

	fixture.runtime.consumer.OnModelBound(actor, candidate.model)
	local other: Types.ActorModelCandidate = StreamUtils.candidate(fixture.stream, "ActorB")
	fixture.runtime.consumer.OnModelUnbound(actor, other.model)
	expect(view:GetModel()).toBe(candidate.model)
	expect(fixture.runtime.registry.GetActorViewByModel(candidate.model)).toBe(view)
	expect(changes).toBe(0)
end)

it("ignores repeated terminal callbacks and all retained lifecycle callbacks after shutdown", function()
	TestUtils.baseline(fixture)
	local actor: Types.ActorStreamRecord = TestUtils.actor(fixture)
	fixture.runtime.consumer.OnActorHalted(actor)
	fixture.runtime.consumer.OnActorHalted(actor)
	expect(#fixture.faults).toBe(1)
	fixture.runtime:Destroy()
	local candidate: Types.ActorModelCandidate = StreamUtils.candidate(fixture.stream, "ActorA")
	fixture.runtime.consumer.OnModelBound(actor, candidate.model)
	fixture.runtime.consumer.OnModelUnbound(actor, candidate.model)
	fixture.runtime.consumer.OnActorHalted(actor)
	fixture.runtime.consumer.OnActorRemoved(actor)
	expect(fixture.runtime:_InspectForTests(1)).toBeNil()
	expect(fixture.runtime.registry.GetAllActorViews()).toEqual({})
	expect(#fixture.faults).toBe(1)
	expect(fixture.requests).toEqual({})
end)
