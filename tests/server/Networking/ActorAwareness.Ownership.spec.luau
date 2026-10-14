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
local TestUtils = require(script.Parent.Parent.Utils.Networking.AwarenessTestUtils)

local fixture: TestUtils.Fixture
local runtime: Types.Runtime
local owner: Player
local other: Player
local actor: ActorTypes.Actor
beforeEach(function()
	fixture = TestUtils.new()
	owner = TestUtils.player(fixture)
	other = TestUtils.player(fixture)
	actor = TestUtils.actor(fixture, owner)
end)
afterEach(function()
	TestUtils.destroy(fixture)
end)

local function start(): ()
	runtime = TestUtils.start(fixture)
	TestUtils.ready(fixture, owner)
	TestUtils.ready(fixture, other)
	TestUtils.drain(fixture)
end

it("resolves both directions of the direct Player Character association", function()
	start()
	expect(runtime:GetActorForPlayer(owner)).toBe(actor)
	expect(runtime:GetPlayerForActor(actor)).toBe(owner)
	expect(runtime:GetActorForPlayer(other)).toBeNil()
end)

it("keeps NPC awareness independent from the absence of an Owner recipient", function()
	start()
	local npc: ActorTypes.Actor = TestUtils.actor(fixture, nil)
	TestUtils.drain(fixture)
	expect(runtime:GetPlayerForActor(npc)).toBeNil()
	expect(runtime:IsAware(owner, npc)).toBe(true)
	local handle: number? = runtime:GetHandle(owner, npc)
	assert(handle ~= nil, "Expected NPC handle")
	expect(TestUtils.baseline(fixture, owner, handle)).toEqual({ ["Game.Public"] = { value = 10 } })
end)

it("serializes Owner truth only to the associated Player while both recipients remain aware", function()
	start()
	local ownerHandle: number? = runtime:GetHandle(owner, actor)
	local otherHandle: number? = runtime:GetHandle(other, actor)
	assert(ownerHandle ~= nil and otherHandle ~= nil, "Expected aware handles")
	expect(TestUtils.baseline(fixture, owner, ownerHandle)).toEqual({
		["Game.Public"] = { value = 10 },
		["Game.Private"] = { value = 20 },
	})
	expect(TestUtils.baseline(fixture, other, otherHandle)).toEqual({ ["Game.Public"] = { value = 10 } })
	expect(runtime:IsAware(other, actor)).toBe(true)
end)

it("does not inherit ownership through a matching numeric UserId on a later session", function()
	-- Table identities model two Player sessions with the same UserId. All engine access is injected.
	local previous: Player = { UserId = 42 } :: any
	local later: Player = { UserId = 42 } :: any
	assert(actor.model ~= nil, "Expected Character Model")
	fixture.owners[actor.model] = previous
	runtime = TestUtils.start(fixture)
	TestUtils.ready(fixture, previous)
	TestUtils.ready(fixture, later)
	TestUtils.drain(fixture)
	expect(runtime:GetActorForPlayer(previous)).toBe(actor)
	expect(runtime:GetActorForPlayer(later)).toBeNil()
	local handle: number? = runtime:GetHandle(later, actor)
	assert(handle ~= nil, "Expected later session to be aware")
	expect(TestUtils.baseline(fixture, later, handle)).toEqual({ ["Game.Public"] = { value = 10 } })
end)

it("replaces old and new owner baselines without replacing an unrelated recipient", function()
	start()
	local unrelated: Player = TestUtils.player(fixture)
	TestUtils.ready(fixture, unrelated)
	TestUtils.drain(fixture)
	fixture.deliveries = {}
	assert(actor.model ~= nil, "Expected Character")
	fixture.owners[actor.model] = other
	runtime:RefreshPlayerAssociation(actor)
	TestUtils.drain(fixture)
	local oldHandle: number? = runtime:GetHandle(owner, actor)
	local newHandle: number? = runtime:GetHandle(other, actor)
	assert(oldHandle ~= nil and newHandle ~= nil, "Expected unchanged awareness")
	expect(TestUtils.baseline(fixture, owner, oldHandle)).toEqual({ ["Game.Public"] = { value = 10 } })
	expect(TestUtils.baseline(fixture, other, newHandle)).toEqual({
		["Game.Public"] = { value = 10 },
		["Game.Private"] = { value = 20 },
	})
	expect(TestUtils.records(fixture, unrelated)).toEqual({})
	expect(runtime:GetActorForPlayer(owner)).toBeNil()
	expect(runtime:GetActorForPlayer(other)).toBe(actor)
end)

for _, toNil: boolean in { true, false } do
	it(
		"reconciles only the existing side when association changes " .. (if toNil then "to nil" else "from nil"),
		function()
			assert(actor.model ~= nil, "Expected Model")
			if not toNil then
				fixture.owners[actor.model] = nil
			end
			start()
			fixture.deliveries = {}
			fixture.owners[actor.model] = if toNil then nil else owner
			runtime:RefreshPlayerAssociation(actor)
			TestUtils.drain(fixture)
			expect(#TestUtils.kind(fixture, owner, "BaselineBegin")).toBe(1)
			expect(TestUtils.records(fixture, other)).toEqual({})
		end
	)
end

it("deduplicates unchanged association notifications without consuming a generation", function()
	start()
	fixture.deliveries = {}
	runtime:RefreshPlayerAssociation(actor)
	runtime:RefreshPlayerAssociation(actor)
	TestUtils.drain(fixture)
	expect(fixture.deliveries).toEqual({})
end)

it("captures the latest visibility once when reassociation overlaps a pending replacement", function()
	start()
	local handle: number? = runtime:GetHandle(owner, actor)
	assert(handle ~= nil and actor.model ~= nil, "Expected owner stream")
	fixture.deliveries = {}
	expect(runtime:RequestReplacementBaseline(owner, handle, "TestRecovery")).toBe(true)
	fixture.owners[actor.model] = other
	runtime:RefreshPlayerAssociation(actor)
	TestUtils.drain(fixture)
	expect(#TestUtils.kind(fixture, owner, "BaselineEnd")).toBe(1)
	expect(TestUtils.baseline(fixture, owner, handle)).toEqual({ ["Game.Public"] = { value = 10 } })
end)

it("unregistering an old character does not erase the player's replacement Actor mapping", function()
	start()
	assert(actor.model ~= nil, "Expected old Model")
	fixture.owners[actor.model] = nil
	runtime:RefreshPlayerAssociation(actor)
	local replacement: ActorTypes.Actor = TestUtils.actor(fixture, owner)
	runtime:OnActorUnregistering(actor)
	expect(runtime:GetActorForPlayer(owner)).toBe(replacement)
	expect(runtime:GetPlayerForActor(actor)).toBeNil()
	expect(runtime:GetPlayerForActor(replacement)).toBe(owner)
end)
