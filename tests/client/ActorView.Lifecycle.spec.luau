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
local TestUtils = require(script.Parent.Utils.ActorViewTestUtils)
local StreamUtils = require(script.Parent.Utils.ActorStreamTestUtils)

local fixture: TestUtils.Fixture
beforeEach(function()
	fixture = TestUtils.new()
end)
afterEach(function()
	TestUtils.destroy(fixture)
end)

it("reflects N4 stream-in, stream-out and a new Model binding without changing domain truth or revision", function()
	TestUtils.baseline(fixture)
	local view: PublicTypes.ActorView = TestUtils.view(fixture)
	local domain: PublicTypes.DomainView = TestUtils.domain(fixture)
	local previous: any = domain:GetState()
	local changes: { any } = {}
	table.insert(
		fixture.connections,
		view.OnModelChanged:Connect(function(old: Model?, current: Model?)
			table.insert(changes, { previous = old, current = current, observed = view:GetModel() })
		end)
	)
	local first: ClientNetworkingTypes.ActorModelCandidate = StreamUtils.candidate(fixture.stream, "ActorA")
	local second: ClientNetworkingTypes.ActorModelCandidate = StreamUtils.candidate(fixture.stream, "ActorA")
	expect(fixture.runtime.registry.GetActorViewByModel(first.model)).toBeNil()
	StreamUtils.add(fixture.stream, first)
	expect(view:GetModel()).toBe(first.model)
	expect(fixture.runtime.registry.GetActorViewByModel(first.model)).toBe(view)
	StreamUtils.remove(fixture.stream, first)
	expect(view:GetModel()).toBeNil()
	expect(fixture.runtime.registry.GetActorViewByModel(first.model)).toBeNil()
	expect(TestUtils.view(fixture)).toBe(view)
	StreamUtils.add(fixture.stream, second)
	expect(view:GetModel()).toBe(second.model)
	expect(fixture.runtime.registry.GetActorViewByModel(second.model)).toBe(view)
	expect(changes).toEqual({
		{ current = first.model, observed = first.model },
		{ previous = first.model },
		{ current = second.model, observed = second.model },
	})
	expect(TestUtils.domain(fixture)).toBe(domain)
	expect(domain:GetState()).toBe(previous)
	expect(fixture.requests).toEqual({})
	TestUtils.commit(fixture, 11, { TestUtils.patch(75) })
	expect(domain:GetState().current).toBe(75)
	expect(fixture.stream.scans).toBe(1)
end)

it("does not synthesize OnModelChanged for a binding already present at ActorView creation", function()
	local candidate: ClientNetworkingTypes.ActorModelCandidate = StreamUtils.candidate(fixture.stream, "ActorA")
	StreamUtils.add(fixture.stream, candidate)
	local changes: number = 0
	table.insert(
		fixture.connections,
		fixture.runtime.registry.OnActorViewAdded:Connect(function(view: PublicTypes.ActorView)
			table.insert(
				fixture.connections,
				view.OnModelChanged:Connect(function(_old: Model?, _current: Model?)
					changes += 1
				end)
			)
		end)
	)
	TestUtils.baseline(fixture)
	expect(TestUtils.view(fixture):GetModel()).toBe(candidate.model)
	expect(changes).toBe(0)
	StreamUtils.remove(fixture.stream, candidate)
	expect(changes).toBe(1)
end)

it("does not double-notify duplicate discovery markers for the same Model", function()
	TestUtils.baseline(fixture)
	local view: PublicTypes.ActorView = TestUtils.view(fixture)
	local changes: number = 0
	table.insert(
		fixture.connections,
		view.OnModelChanged:Connect(function(_old: Model?, _current: Model?)
			changes += 1
		end)
	)
	local first: ClientNetworkingTypes.ActorModelCandidate = StreamUtils.candidate(fixture.stream, "ActorA")
	local duplicate: ClientNetworkingTypes.ActorModelCandidate =
		StreamUtils.candidate(fixture.stream, "ActorA", first.model)
	StreamUtils.add(fixture.stream, first)
	StreamUtils.add(fixture.stream, duplicate)
	StreamUtils.remove(fixture.stream, first)
	expect(view:GetModel()).toBe(first.model)
	expect(changes).toBe(1)
end)

it("keeps Model binding operational during Actor-local recovery", function()
	TestUtils.baseline(fixture)
	local view: PublicTypes.ActorView = TestUtils.view(fixture)
	local previous: any = TestUtils.domain(fixture):GetState()
	TestUtils.commit(fixture, 12)
	local candidate: ClientNetworkingTypes.ActorModelCandidate = StreamUtils.candidate(fixture.stream, "ActorA")
	StreamUtils.add(fixture.stream, candidate)
	expect(view:GetModel()).toBe(candidate.model)
	StreamUtils.remove(fixture.stream, candidate)
	expect(view:GetModel()).toBeNil()
	expect(TestUtils.domain(fixture):GetState()).toBe(previous)
	expect(#fixture.requests).toBe(1)
end)

it("rejects a decoded Model collision without stealing another live Actor's index", function()
	local candidate: ClientNetworkingTypes.ActorModelCandidate = StreamUtils.candidate(fixture.stream, "ActorA")
	StreamUtils.add(fixture.stream, candidate)
	TestUtils.baseline(fixture)
	TestUtils.baseline(fixture, 2, "ActorB")
	local first: PublicTypes.ActorView = TestUtils.view(fixture)
	local second: PublicTypes.ActorView = TestUtils.view(fixture, "ActorB")
	fixture.runtime.consumer.OnModelBound(TestUtils.actor(fixture, 2), candidate.model)
	expect(fixture.runtime.registry.GetActorViewByModel(candidate.model)).toBe(first)
	expect(first:GetModel()).toBe(candidate.model)
	expect(second:GetModel()).toBeNil()
	expect(#fixture.faults).toBe(1)
end)

for _, recovering: boolean in { false, true } do
	it("removes membership, signals and recovery exactly once with recovering=" .. tostring(recovering), function()
		local candidate: ClientNetworkingTypes.ActorModelCandidate = StreamUtils.candidate(fixture.stream, "ActorA")
		StreamUtils.add(fixture.stream, candidate)
		TestUtils.baseline(fixture)
		TestUtils.baseline(fixture, 2, "ActorB")
		local view: PublicTypes.ActorView = TestUtils.view(fixture)
		local domain: PublicTypes.DomainView = TestUtils.domain(fixture)
		local event: SignalTypes.Event<any>? = domain:GetEvent("Depleted")
		assert(event ~= nil, "Expected domain event")
		local other: PublicTypes.ActorView = TestUtils.view(fixture, "ActorB")
		local removed: { PublicTypes.ActorView } = {}
		table.insert(
			fixture.connections,
			fixture.runtime.registry.OnActorViewRemoving:Connect(function(removing: PublicTypes.ActorView)
				table.insert(removed, removing)
			end)
		)
		if recovering then
			TestUtils.commit(fixture, 12)
		end
		local actor: ClientNetworkingTypes.ActorStreamRecord = TestUtils.actor(fixture)
		TestUtils.send(fixture, { { kind = "ActorRemove", handle = 1 } })
		local accepted: boolean, reason: string? =
			StreamUtils.send(fixture.stream, { { kind = "ActorRemove", handle = 1 } })
		expect(accepted).toBe(false)
		expect(reason).toBe("RetiredActorHandle")
		expect(removed).toEqual({ view })
		expect(fixture.runtime.registry.GetActorViewById("ActorA")).toBeNil()
		expect(fixture.runtime.registry.GetActorViewByModel(candidate.model)).toBeNil()
		expect(fixture.runtime.registry.GetAllActorViews()).toEqual({ other })
		local connectedChange: boolean = pcall(function()
			domain.OnChanged:Connect(function(_change: PublicTypes.DomainChange) end)
		end)
		expect(connectedChange).toBe(false)
		local connectedEvent: boolean = pcall(function()
			event:Connect(function(_payload: any) end)
		end)
		expect(connectedEvent).toBe(false)
		local connectedModel: boolean = pcall(function()
			view.OnModelChanged:Connect(function(_old: Model?, _new: Model?) end)
		end)
		expect(connectedModel).toBe(false)
		-- Retained private callbacks cannot resurrect or reconnect the retired identity.
		fixture.runtime.consumer.OnCommitReady(actor, 11, { TestUtils.patch(1) }, {})
		fixture.runtime.consumer.OnBaselineReady(actor, 50, TestUtils.truth(1))
		fixture.runtime.consumer.OnActorRemoved(actor)
		local readable: boolean, state: any = pcall(function(): any
			return domain:GetState()
		end)
		if readable then
			expect(state).toBeNil()
		end
		expect(fixture.runtime.registry.GetActorViewById("ActorA")).toBeNil()
		expect(removed).toEqual({ view })
		expect(#fixture.requests).toBe(if recovering then 1 else 0)
		TestUtils.commit(fixture, 11, { TestUtils.patch(60) }, {}, 2)
		expect(TestUtils.domain(fixture, nil, "ActorB"):GetState().current).toBe(60)
		TestUtils.baseline(fixture, 3, "ActorRespawn")
		expect(TestUtils.view(fixture, "ActorRespawn")).never.toBe(view)
	end)
end

it("retires an incomplete Actor without publishing Added or Removing", function()
	local added: number = 0
	local removing: number = 0
	table.insert(
		fixture.connections,
		fixture.runtime.registry.OnActorViewAdded:Connect(function(_view: PublicTypes.ActorView)
			added += 1
		end)
	)
	table.insert(
		fixture.connections,
		fixture.runtime.registry.OnActorViewRemoving:Connect(function(_view: PublicTypes.ActorView)
			removing += 1
		end)
	)
	TestUtils.send(
		fixture,
		{ { kind = "BaselineBegin", handle = 1, actorId = "ActorA", generation = 1, totalBytes = 1 } }
	)
	local actor: ClientNetworkingTypes.ActorStreamRecord = TestUtils.actor(fixture)
	TestUtils.send(fixture, { { kind = "ActorRemove", handle = 1 } })
	fixture.runtime.consumer.OnBaselineReady(actor, 10, TestUtils.truth())
	expect(added).toBe(0)
	expect(removing).toBe(0)
	expect(fixture.runtime.registry.GetAllActorViews()).toEqual({})
end)

it("invalidates terminally halted truth, stops resync, and preserves identity/Model lifecycle until removal", function()
	TestUtils.baseline(fixture)
	local view: PublicTypes.ActorView = TestUtils.view(fixture)
	local domain: PublicTypes.DomainView = TestUtils.domain(fixture)
	TestUtils.send(fixture, { { kind = "ActorHalt", handle = 1 } })
	local diagnostics: ClientNetworkingTypes.ActorViewDiagnostics? = fixture.runtime:_InspectForTests(1)
	assert(diagnostics ~= nil, "Expected terminal diagnostics")
	expect(diagnostics.status).toBe("Halted")
	local readable: boolean, state: any = pcall(function(): any
		return domain:GetState()
	end)
	if readable then
		expect(state).toBeNil()
	end
	fixture.runtime.consumer.OnCommitReady(TestUtils.actor(fixture), 11, { TestUtils.patch(1) }, {})
	fixture.runtime.consumer.OnBaselineReady(TestUtils.actor(fixture), 50, TestUtils.truth(1))
	expect(fixture.requests).toEqual({})
	local candidate: ClientNetworkingTypes.ActorModelCandidate = StreamUtils.candidate(fixture.stream, "ActorA")
	StreamUtils.add(fixture.stream, candidate)
	expect(view:GetModel()).toBe(candidate.model)
	TestUtils.send(fixture, { { kind = "ActorRemove", handle = 1 } })
	expect(fixture.runtime.registry.GetActorViewById("ActorA")).toBeNil()
end)

it("makes teardown idempotent and ignores all retained decoded callbacks after shutdown", function()
	TestUtils.baseline(fixture)
	local actor: ClientNetworkingTypes.ActorStreamRecord = TestUtils.actor(fixture)
	TestUtils.view(fixture)
	fixture.runtime:Destroy()
	fixture.runtime:Destroy()
	fixture.runtime.consumer.OnBaselineReady(actor, 50, TestUtils.truth())
	fixture.runtime.consumer.OnCommitReady(actor, 51, { TestUtils.patch(1) }, {})
	expect(fixture.runtime.registry.GetAllActorViews()).toEqual({})
	expect(fixture.requests).toEqual({})
end)

it("halts an incomplete initial Actor without ever making its later data public", function()
	TestUtils.send(
		fixture,
		{ { kind = "BaselineBegin", handle = 1, actorId = "ActorA", generation = 1, totalBytes = 1 } }
	)
	local actor: ClientNetworkingTypes.ActorStreamRecord = TestUtils.actor(fixture)
	TestUtils.send(fixture, { { kind = "ActorHalt", handle = 1 } })
	fixture.runtime.consumer.OnBaselineReady(actor, 50, TestUtils.truth())
	expect(fixture.runtime.registry.GetActorViewById("ActorA")).toBeNil()
	expect(fixture.requests).toEqual({})
	local diagnostics: ClientNetworkingTypes.ActorViewDiagnostics? = fixture.runtime:_InspectForTests(1)
	assert(diagnostics ~= nil, "Expected terminal state even without public creation")
	expect(diagnostics.status).toBe("Halted")
end)
