--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local ServerNetworkingTypes = require(KRF.server.Networking.types)
local ActorTypes = require(KRF.server.Actor.types)
local TestUtils = require(script.Parent.Parent.Utils.Networking.AwarenessTestUtils)

local fixture: TestUtils.Fixture
local player: Player
local actor: ActorTypes.Actor

beforeEach(function()
	fixture = TestUtils.new()
	player = TestUtils.player(fixture)
	actor = TestUtils.actor(fixture, nil)
end)

afterEach(function()
	TestUtils.destroy(fixture)
end)

for _, withReason: boolean in { true, false } do
	it(
		"halts a failed Reliable send once and still retires that Actor on removal with reason=" .. tostring(withReason),
		function()
			local attempts: number = 0

			fixture.dependencies.SendReliable = function(_player: Player, _payload: buffer): (boolean, string?)
				attempts += 1

				return false, if withReason then "ForcedSendFailure" else nil
			end

			local runtime: ServerNetworkingTypes.ActorAwarenessRuntime = TestUtils.start(fixture)
			TestUtils.ready(fixture, player)
			local handle: number? = runtime:GetHandle(player, actor)
			assert(handle ~= nil, "Expected stream handle")
			TestUtils.drain(fixture)
			expect(attempts).toBe(1)

			expect(fixture.faults).toEqual({
				{
					player = player,
					actorId = actor:GetId(),
					reason = if withReason then "ForcedSendFailure" else "ActorSendFailed",
				},
			})

			local success: boolean, reason: string? = runtime:RequestReplacementBaseline(player, handle)
			expect(success).toBe(false)
			expect(reason).toBe("ActorStreamHalted")

			fixture.dependencies.SendReliable = function(recipient: Player, payload: buffer): (boolean, string?)
				table.insert(fixture.deliveries, { player = recipient, payload = payload })

				return true, nil
			end

			runtime:OnActorUnregistering(actor)
			TestUtils.drain(fixture)
			expect(TestUtils.records(fixture, player)).toEqual({ { kind = "ActorRemove", handle = handle } })
		end
	)
end

it("reports a detached canonical Actor instead of inventing replacement truth", function()
	local runtime: ServerNetworkingTypes.ActorAwarenessRuntime = TestUtils.start(fixture)
	TestUtils.ready(fixture, player)
	TestUtils.drain(fixture)
	local handle: number? = runtime:GetHandle(player, actor)
	assert(handle ~= nil, "Expected aware stream")
	fixture.publication:DetachActor(actor)
	fixture.deliveries = {}
	local success: boolean, reason: string? = runtime:RequestReplacementBaseline(player, handle)
	expect(success).toBe(false)
	expect(reason).toBe("ActorStreamHalted")
	expect(fixture.faults).toEqual({ { player = player, actorId = actor:GetId(), reason = "ActorBaselineMissing" } })
	TestUtils.drain(fixture)
	expect(TestUtils.records(fixture, player)).toEqual({ { kind = "ActorHalt", handle = handle } })
end)

it("rejects invalid canonical truth before returning baseline bytes", function()
	fixture.publication.CaptureBaseline = function(
		_self: ServerNetworkingTypes.PublicationRuntime,
		_actor: ActorTypes.Actor
	): ServerNetworkingTypes.PublicationBaseline?
		return { sequence = 0, domains = { ["Game.Public"] = { value = 256 } } }
	end

	TestUtils.start(fixture)
	TestUtils.ready(fixture, player)
	TestUtils.drain(fixture)
	expect(fixture.deliveries).toEqual({})
	expect(fixture.faults).toEqual({ { player = player, actorId = actor:GetId(), reason = "InvalidActorBaseline" } })
end)

it("fails generation exhaustion without reusing an earlier completed generation", function()
	fixture.options.maxGeneration = 1

	local runtime: ServerNetworkingTypes.ActorAwarenessRuntime = TestUtils.start(fixture)
	TestUtils.ready(fixture, player)
	TestUtils.drain(fixture)
	local handle: number? = runtime:GetHandle(player, actor)
	assert(handle ~= nil, "Expected completed initial stream")
	fixture.deliveries = {}
	local success: boolean, reason: string? = runtime:RequestReplacementBaseline(player, handle)
	expect(success).toBe(false)
	expect(reason).toBe("ActorStreamHalted")
	TestUtils.drain(fixture)
	expect(TestUtils.records(fixture, player)).toEqual({ { kind = "ActorHalt", handle = handle } })
	expect(fixture.faults).toEqual({ { player = player, actorId = actor:GetId(), reason = "ActorGenerationExhausted" } })
end)

it("fails an exhausted baseline revision without publishing a completed baseline", function()
	fixture.options.maxRevision = 0
	TestUtils.start(fixture)
	TestUtils.ready(fixture, player)
	TestUtils.drain(fixture)
	expect(TestUtils.kind(fixture, player, "BaselineEnd")).toEqual({})
	expect(fixture.faults).toEqual({ { player = player, actorId = actor:GetId(), reason = "ActorRevisionExhausted" } })
end)

it("preserves unsent baseline and live work when the current byte budget cannot fit it", function()
	local runtime: ServerNetworkingTypes.ActorAwarenessRuntime = TestUtils.start(fixture)
	TestUtils.ready(fixture, player)
	runtime:Step(1, 1)
	expect(fixture.deliveries).toEqual({})
	runtime:Step(256, 1)
	local sent: number = #fixture.deliveries
	runtime:Step(26, 1)
	expect(#fixture.deliveries).toBe(sent)
	TestUtils.drain(fixture)
	fixture.deliveries = {}
	fixture.publicDomain.value = 12
	fixture.publicDomain.callbacks[actor]()
	runtime:Step(1, 1)
	expect(fixture.deliveries).toEqual({})
	TestUtils.drain(fixture)
	expect(#TestUtils.kind(fixture, player, "Commit")).toBe(1)
end)

it("ignores non-Ready notifications, disabled Actors, unknown Models and retained callbacks after destroy", function()
	local runtime: ServerNetworkingTypes.ActorAwarenessRuntime = TestUtils.start(fixture)
	fixture.readyObservers[1](player)
	expect(runtime:GetHandle(player, actor)).toBeNil()
	actor.enabled = false
	TestUtils.ready(fixture, player)
	expect(runtime:GetHandle(player, actor)).toBeNil()
	local unknown: Model = Instance.new("Model")
	table.insert(fixture.instances, unknown)
	fixture.associationObservers[1](unknown)
	local ready: (Player) -> () = fixture.readyObservers[1]
	local changed: (Model) -> () = fixture.associationObservers[1]
	runtime:Destroy()
	ready(player)
	changed(unknown)
	runtime:OnActorRegistered(actor)
	runtime:OnActorUnregistering(actor)
	runtime:RefreshPlayerAssociation(actor)
	expect(runtime:GetActorForPlayer(player)).toBeNil()
	expect(fixture.faults).toEqual({})
end)
