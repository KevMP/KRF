--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local ActorTypes = require(KRF.server.Actor.types)
local NetworkingTypes = require(KRF.server.Networking.types)
local Commands = require(script.Parent.Parent.Parent.shared.Utils.Networking.CommandTestUtils)
local TestUtils = require(script.Parent.Parent.Utils.Networking.AwarenessTestUtils)

local fixture: TestUtils.Fixture

beforeEach(function()
	fixture = TestUtils.new()
end)

afterEach(function()
	TestUtils.destroy(fixture)
end)

it("does not treat an aware client or matching ownerUserId as OwnerActor authority", function()
	local authorization: Commands.Authorization = Commands.authorization()
	local player: Player = { UserId = 42 } :: any
	local other: Player = { UserId = 42 } :: any
	local actor: ActorTypes.Actor = TestUtils.actor(fixture, other)

	other.Character = actor.model

	local runtime: NetworkingTypes.ActorAwarenessRuntime = TestUtils.start(fixture)
	TestUtils.ready(fixture, player)
	TestUtils.ready(fixture, other)
	TestUtils.drain(fixture)
	expect(runtime:IsAware(player, actor)).toBe(true)
	expect(runtime:GetPlayerForActor(actor)).toBe(other)

	local allowed: boolean, reason: string? = authorization.OwnerActor(
		{ player = player, actor = actor },
		{ ownerUserId = 42 }
	)

	expect(allowed).toBe(false)
	expect(type(reason)).toBe("string")
end)

it("authorizes the Player's directly associated Character Actor and denies an unassociated NPC", function()
	local authorization: Commands.Authorization = Commands.authorization()
	local player: Player = {} :: any
	local character: ActorTypes.Actor = TestUtils.actor(fixture, player)
	local npc: ActorTypes.Actor = TestUtils.actor(fixture)

	player.Character = character.model

	local runtime: NetworkingTypes.ActorAwarenessRuntime = TestUtils.start(fixture)
	TestUtils.ready(fixture, player)
	TestUtils.drain(fixture)
	expect(runtime:GetActorForPlayer(player)).toBe(character)
	expect(runtime:GetPlayerForActor(character)).toBe(player)
	local allowed: boolean, reason: string? = authorization.OwnerActor({ player = player, actor = character }, nil)
	expect(allowed).toBe(true)
	expect(reason).toBeNil()
	expect(runtime:IsAware(player, npc)).toBe(true)
	expect(runtime:GetPlayerForActor(npc)).toBeNil()
	allowed, reason = authorization.OwnerActor({ player = player, actor = npc }, nil)
	expect(allowed).toBe(false)
	expect(type(reason)).toBe("string")
end)

it("loses old Character authority when the Player associates with a new Actor", function()
	local authorization: Commands.Authorization = Commands.authorization()
	local player: Player = {} :: any
	local previous: ActorTypes.Actor = TestUtils.actor(fixture, player)
	local current: ActorTypes.Actor = TestUtils.actor(fixture)

	player.Character = previous.model

	local runtime: NetworkingTypes.ActorAwarenessRuntime = TestUtils.start(fixture)
	TestUtils.ready(fixture, player)
	player.Character = current.model
	TestUtils.associate(fixture, previous, nil)
	TestUtils.associate(fixture, current, player)
	expect(runtime:GetActorForPlayer(player)).toBe(current)
	local allowed: boolean, reason: string? = authorization.OwnerActor({ player = player, actor = previous }, nil)
	expect(allowed).toBe(false)
	expect(type(reason)).toBe("string")
	allowed, reason = authorization.OwnerActor({ player = player, actor = current }, nil)
	expect(allowed).toBe(true)
	expect(reason).toBeNil()
end)
