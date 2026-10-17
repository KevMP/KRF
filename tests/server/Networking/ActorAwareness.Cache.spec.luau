--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF

local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local ActorTypes = require(KRF.server.Actor.types)
local Types = require(KRF.server.Networking.AwarenessTypes)
local PublicationTypes = require(KRF.server.Networking.PublicationTypes)
local TestUtils = require(script.Parent.Parent.Utils.Networking.AwarenessTestUtils)

type CachedBaseline = { sequence: number, public: { body: buffer }?, owner: { body: buffer }? }

local fixture: TestUtils.Fixture
beforeEach(function()
	fixture = TestUtils.new()
end)
afterEach(function()
	TestUtils.destroy(fixture)
end)

for _, ownerOnly: boolean in { false, true } do
	it(
		"expires both reusable projections without changing in-flight bodies for ownerOnly=" .. tostring(ownerOnly),
		function()
			fixture.options.maxChunkBytes = 1
			local owner: Player = TestUtils.player(fixture)
			local observer: Player = TestUtils.player(fixture)
			local actor: ActorTypes.Actor = TestUtils.actor(fixture, owner)
			local unaffected: ActorTypes.Actor = TestUtils.actor(fixture, nil)
			local runtime: Types.Runtime = TestUtils.start(fixture)
			TestUtils.ready(fixture, owner)
			TestUtils.ready(fixture, observer)
			-- Inspect retention directly; garbage collection timing cannot prove cache eviction reliably.
			local reusable: { [ActorTypes.Actor]: CachedBaseline } = (runtime :: any).projections.baselines
			local initial: CachedBaseline = reusable[actor]
			local other: CachedBaseline = reusable[unaffected]
			assert(initial.public ~= nil and initial.owner ~= nil, "Expected cached public and Owner projections")
			local publicBytes: string = buffer.tostring(initial.public.body)
			local ownerBytes: string = buffer.tostring(initial.owner.body)
			runtime:Step(512, 4)
			expect(#TestUtils.kind(fixture, owner, "BaselineBegin")).toBe(2)
			expect(TestUtils.kind(fixture, owner, "BaselineEnd")).toEqual({})
			local domain: typeof(fixture.publicDomain) = if ownerOnly then fixture.ownerDomain else fixture.publicDomain
			domain.value += 1
			domain.callbacks[actor]()
			expect(reusable[actor]).toBeNil()
			expect(reusable[unaffected]).toBe(other)
			expect(buffer.tostring(initial.public.body)).toBe(publicBytes)
			expect(buffer.tostring(initial.owner.body)).toBe(ownerBytes)
			local late: Player = TestUtils.player(fixture)
			TestUtils.ready(fixture, late)
			expect(reusable[actor].sequence > initial.sequence).toBe(true)
			TestUtils.drain(fixture)
			local ownerHandle: number? = runtime:GetHandle(owner, actor)
			local observerHandle: number? = runtime:GetHandle(observer, actor)
			local lateHandle: number? = runtime:GetHandle(late, actor)
			assert(ownerHandle ~= nil and observerHandle ~= nil and lateHandle ~= nil, "Expected independent streams")
			expect(TestUtils.baseline(fixture, owner, ownerHandle)).toEqual({
				["Game.Public"] = { value = 10 },
				["Game.Private"] = { value = 20 },
			})
			expect(TestUtils.baseline(fixture, observer, observerHandle)).toEqual({ ["Game.Public"] = { value = 10 } })
			expect(TestUtils.baseline(fixture, late, lateHandle)).toEqual({
				["Game.Public"] = { value = if ownerOnly then 10 else 11 },
			})
			local commits: { any } = TestUtils.kind(fixture, owner, "Commit")
			expect(#commits).toBe(1)
			expect(commits[1].handle).toBe(ownerHandle)
			expect(#TestUtils.kind(fixture, observer, "Commit")).toBe(if ownerOnly then 0 else 1)
			expect(TestUtils.kind(fixture, late, "Commit")).toEqual({})
			expect(fixture.faults).toEqual({})
		end
	)
end

it("releases stale encoded bodies on a commit even when no Ready recipients remain", function()
	local player: Player = TestUtils.player(fixture)
	local actor: ActorTypes.Actor = TestUtils.actor(fixture, player)
	local runtime: Types.Runtime = TestUtils.start(fixture)
	TestUtils.ready(fixture, player)
	TestUtils.drain(fixture)
	local reusable: { [ActorTypes.Actor]: CachedBaseline } = (runtime :: any).projections.baselines
	expect(reusable[actor]).never.toBeNil()
	TestUtils.close(fixture, player)
	fixture.deliveries = {}
	fixture.ownerDomain.value = 21
	fixture.ownerDomain.callbacks[actor]()
	expect(reusable[actor]).toBeNil()
	TestUtils.drain(fixture)
	expect(fixture.deliveries).toEqual({})
end)

it("retains a current-sequence cache captured by an earlier committed observer", function()
	local owner: Player = TestUtils.player(fixture)
	local actor: ActorTypes.Actor = TestUtils.actor(fixture, owner)
	local runtime: Types.Runtime? = nil
	local handle: number? = nil
	fixture.publication:ObserveCommits(function(commit: PublicationTypes.Commit)
		if commit.actor ~= actor then
			return
		end
		assert(runtime ~= nil and handle ~= nil, "Expected established stream before publication")
		local accepted: boolean, reason: string? = runtime:RequestReplacementBaseline(owner, handle, "EarlierObserver")
		expect(accepted).toBe(true)
		expect(reason).toBeNil()
	end)
	runtime = TestUtils.start(fixture)
	TestUtils.ready(fixture, owner)
	TestUtils.drain(fixture)
	handle = runtime:GetHandle(owner, actor)
	fixture.publicDomain.value = 11
	fixture.publicDomain.callbacks[actor]()
	local reusable: { [ActorTypes.Actor]: CachedBaseline } = (runtime :: any).projections.baselines
	expect(reusable[actor].sequence).toBe(fixture.publication:GetActorSequence(actor))
	TestUtils.drain(fixture)
	assert(handle ~= nil, "Expected stable handle")
	expect(TestUtils.baseline(fixture, owner, handle)).toEqual({
		["Game.Public"] = { value = 11 },
		["Game.Private"] = { value = 20 },
	})
end)
