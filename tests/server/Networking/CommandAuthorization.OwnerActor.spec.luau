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
local TestUtils = require(script.Parent.Parent.Utils.Networking.AwarenessTestUtils)

local fixture: TestUtils.Fixture

beforeEach(function()
	fixture = TestUtils.new()
end)

afterEach(function()
	TestUtils.destroy(fixture)
end)

-- The production server command runtime does not exist yet. Do not call the
-- helper with a made-up context: that would leave this N4 runtime disconnected
-- from authorization and could reward a direct Player.Character comparison.
-- These are intentional failing tests, not skipped tests or authorization proof.
it("[blocked integration] denies an aware client with matching UserId when N4 associates another Player", function()
	local player: Player = { UserId = 42 } :: any
	local other: Player = { UserId = 42 } :: any
	local actor: ActorTypes.Actor = TestUtils.actor(fixture, other)

	-- Deliberately disagree with the injected N4 association: direct Character
	-- comparison would allow this requester, whereas the N4 mapping denies it.
	player.Character = actor.model

	local runtime: NetworkingTypes.ActorAwarenessRuntime = TestUtils.start(fixture)
	TestUtils.ready(fixture, player)
	TestUtils.ready(fixture, other)
	TestUtils.drain(fixture)
	expect(runtime:IsAware(player, actor)).toBe(true)
	expect(runtime:GetPlayerForActor(actor)).toBe(other)

	error(
		"[N9 blocked integration] OwnerActor must deny this aware requester despite Character/UserId matches; "
			.. "bind authorization through the production server command runtime to this N4 association dependency (#79.12)",
		0
	)
end)

it("[blocked integration] accepts the N4-associated Character Actor and denies an unassociated NPC", function()
	local player: Player = {} :: any
	local character: ActorTypes.Actor = TestUtils.actor(fixture, player)
	local npc: ActorTypes.Actor = TestUtils.actor(fixture)

	player.Character = character.model

	local runtime: NetworkingTypes.ActorAwarenessRuntime = TestUtils.start(fixture)
	TestUtils.ready(fixture, player)
	TestUtils.drain(fixture)
	expect(runtime:GetActorForPlayer(player)).toBe(character)
	expect(runtime:GetPlayerForActor(character)).toBe(player)
	expect(runtime:IsAware(player, npc)).toBe(true)
	expect(runtime:GetPlayerForActor(npc)).toBeNil()

	error(
		"[N9 blocked integration] OwnerActor must accept the N4-associated Character Actor and deny the NPC; "
			.. "the production server command runtime must supply this N4 association dependency (#79.12)",
		0
	)
end)

it("[blocked integration] follows N4 reassociation from the previous Actor to the current Actor", function()
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
	expect(runtime:GetPlayerForActor(previous)).toBeNil()
	expect(runtime:GetPlayerForActor(current)).toBe(player)

	error(
		"[N9 blocked integration] OwnerActor must deny the previous Actor and accept the current N4 association; "
			.. "exercise the production server command runtime binding, not a fabricated authorizer context (#79.12)",
		0
	)
end)
