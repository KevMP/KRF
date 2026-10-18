--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF

local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local ActorTypes = require(KRF.server.Actor.types)
local ServerNetworkingTypes = require(KRF.server.Networking.types)

local Selection: ServerNetworkingTypes.ActorRecipientSelectionModule =
	require(KRF.server.Networking.utils.ActorRecipientSelection)

local TestUtils = require(script.Parent.Parent.Utils.Networking.AwarenessTestUtils)

local originalSelection: typeof(Selection.ShouldBeAware) = Selection.ShouldBeAware
local fixture: TestUtils.Fixture

beforeEach(function()
	fixture = TestUtils.new()
end)

afterEach(function()
	Selection.ShouldBeAware = originalSelection
	TestUtils.destroy(fixture)
end)

for _, actorFirst: boolean in { true, false } do
	it(
		"uses the private selection policy when "
			.. (if actorFirst then "a connection becomes Ready" else "an Actor registers"),
		function()
			local selected: Player = TestUtils.player(fixture)
			local excluded: Player = TestUtils.player(fixture)
			local evaluated: { [Player]: ActorTypes.Actor } = {}

			Selection.ShouldBeAware = function(player: Player, actor: ActorTypes.Actor): boolean
				evaluated[player] = actor

				return player == selected
			end

			local actor: ActorTypes.Actor? = if actorFirst then TestUtils.actor(fixture, nil) else nil
			local runtime: ServerNetworkingTypes.ActorAwarenessRuntime = TestUtils.start(fixture)
			TestUtils.ready(fixture, selected)
			TestUtils.ready(fixture, excluded)

			if actor == nil then
				actor = TestUtils.actor(fixture, nil)
			end

			assert(actor ~= nil, "Expected registered Actor")
			expect(evaluated).toEqual({ [selected] = actor, [excluded] = actor })
			expect(runtime:IsAware(selected, actor)).toBe(true)
			expect(runtime:GetHandle(excluded, actor)).toBeNil()
			TestUtils.drain(fixture)
			expect(#TestUtils.kind(fixture, selected, "BaselineEnd")).toBe(1)
			expect(TestUtils.records(fixture, excluded)).toEqual({})
		end
	)
end

it("keeps Ready admission separate from the M0 policy that selects every recipient", function()
	local first: Player = TestUtils.player(fixture)
	local second: Player = TestUtils.player(fixture)
	local runtime: ServerNetworkingTypes.ActorAwarenessRuntime = TestUtils.start(fixture)
	TestUtils.ready(fixture, first)
	TestUtils.ready(fixture, second)
	local actor: ActorTypes.Actor = TestUtils.actor(fixture, nil)
	expect(Selection.ShouldBeAware(first, actor)).toBe(true)
	expect(Selection.ShouldBeAware(second, actor)).toBe(true)
	expect(runtime:IsAware(first, actor)).toBe(true)
	expect(runtime:IsAware(second, actor)).toBe(true)
	local evaluations: number = 0

	Selection.ShouldBeAware = function(_player: Player, _actor: ActorTypes.Actor): boolean
		evaluations += 1

		return true
	end

	fixture.readyPlayers[first] = nil

	local later: ActorTypes.Actor = TestUtils.actor(fixture, nil)
	expect(evaluations).toBe(1)
	expect(runtime:IsAware(first, later)).toBe(false)
	expect(runtime:IsAware(second, later)).toBe(true)
end)
