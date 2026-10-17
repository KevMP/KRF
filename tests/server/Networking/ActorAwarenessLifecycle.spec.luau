--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local afterEach: any = JestGlobals.afterEach
local ActorTypes = require(KRF.server.Actor.types)
local Types = require(KRF.server.Networking.AwarenessTypes)
local Lifecycle = require(KRF.server.Networking.ActorAwarenessLifecycle)
local ActorEntity = require(KRF.server.Actor.ActorEntity)
local TestUtils = require(script.Parent.Parent.Utils.Networking.AwarenessTestUtils)

afterEach(function()
	Lifecycle.Install(nil)
end)

it("makes lifecycle hooks harmless before installation and after the installed runtime is released", function()
	Lifecycle.Install(nil)
	local unbound: ActorTypes.Actor = ActorEntity.new()
	Lifecycle.Register(unbound)
	Lifecycle.Unregister(unbound)
	local fixture: TestUtils.Fixture = TestUtils.new()
	local runtime: Types.Runtime = TestUtils.start(fixture)
	Lifecycle.Install(runtime)
	local actor: ActorTypes.Actor = TestUtils.actor(fixture, nil)
	local player: Player = TestUtils.player(fixture)
	TestUtils.ready(fixture, player)
	expect(runtime:IsAware(player, actor)).toBe(true)
	Lifecycle.Install(nil)
	Lifecycle.Unregister(actor)
	expect(runtime:IsAware(player, actor)).toBe(true)
	TestUtils.destroy(fixture)
	Lifecycle.Register(unbound)
	Lifecycle.Unregister(unbound)
end)
