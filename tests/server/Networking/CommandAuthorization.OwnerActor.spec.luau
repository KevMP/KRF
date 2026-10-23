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

local Commands = require(script.Parent.Parent.Utils.Networking.CommandRuntimeTestUtils)
local Authorization = require(KRF.server.Networking.CommandAuthorization)
local commands: Commands.Fixture? = nil

local fixture: TestUtils.Fixture

beforeEach(function()
	fixture = TestUtils.new()
end)

afterEach(function()
	if commands ~= nil then
		commands.runtime:Destroy()
		commands = nil
	end

	TestUtils.destroy(fixture)
end)

local function execute(player: Player, other: Player, actor: ActorTypes.Actor, id: number): string
	if commands == nil then
		commands = Commands.bind(fixture, player, other, actor, {
			{
				id = "Game.Command",
				target = "Actor",
				authorize = Authorization.OwnerActor,
				handle = function(
					_context: NetworkingTypes.CommandContext,
					_request: any
				): NetworkingTypes.CommandHandlerResult
					return { accepted = true }
				end,
			},
		})
	end

	local current: Commands.Fixture = commands :: Commands.Fixture
	Commands.send(current, id, nil, actor)
	local results = Commands.results(current)

	return results[#results].status
end

it("denies an aware client with matching UserId when N4 associates another Player", function()
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

	expect(execute(player, other, actor, 1)).toBe("Rejected")
end)

it("accepts the N4-associated Character Actor and denies an unassociated NPC", function()
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

	expect(execute(player, player, character, 1)).toBe("Accepted")
	expect(execute(player, player, npc, 2)).toBe("Rejected")
end)

it("follows N4 reassociation from the previous Actor to the current Actor", function()
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

	expect(execute(player, player, previous, 1)).toBe("Rejected")
	expect(execute(player, player, current, 2)).toBe("Accepted")
end)
