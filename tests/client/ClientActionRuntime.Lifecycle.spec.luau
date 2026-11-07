--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local ActorTypes = require(KRF.client.Actor.types)
local Types = require(KRF.client.Action.types)
local Actor = require(KRF.client.Actor.ActorView)
local Registry = require(KRF.client.Actor.utils.ActorViewRegistryState)
local Owner = require(KRF.client.Action.ClientActionOwner)
local SequenceUtils = require(script.Parent.Utils.SequenceTestUtils)
local ActorUtils = require(script.Parent.Utils.ActorViewTestUtils)
local Utils = require(script.Parent.Utils.ActionRouteTestUtils)
local fixture: Utils.Fixture
local stream: ActorUtils.Fixture

beforeEach(function()
	fixture = Utils.new()
	stream = ActorUtils.new()
end)

afterEach(function()
	ActorUtils.destroy(stream)
	Utils.destroy(fixture)
end)

it("rejects a lookalike or stale Actor object even when its ID and availability match a current view", function()
	local fake: ActorTypes.ActorViewOwner = assert(Actor.new("ActorA", nil, {}))
	expect(fake.view:IsAvailable()).toBe(true)
	expect({ fixture.owner.SetControlledActor(fake.view) }).toEqual({ false, "ActorViewUnavailable" })

	expect({ fixture.owner.SetProfileSource(fake.view, "Base", { routes = { Utils.fixed() } }) }).toEqual({
		false,
		"ActorViewUnavailable",
	})

	expect({ fixture.owner.RemoveProfileSource(fake.view, "Base") }).toEqual({ false, "ActorViewUnavailable" })
	expect(fixture.owner.GetEffectiveRoute(fake.view, Utils.key())).toBeNil()
	fake:Destroy()
end)

for _, path: string in { "Halt", "Remove", "Reset" } do
	it("synchronously retires profiles and selected identity on authoritative " .. path, function()
		ActorUtils.baseline(stream, 1, "RuntimeActor")
		local actor: ActorTypes.ActorView = ActorUtils.view(stream, "RuntimeActor")
		Utils.set(fixture, { Utils.fixed() }, "Base", nil, actor)
		Utils.select(fixture, actor)
		Utils.emit(fixture, 0)
		table.clear(fixture.transitions)

		if path == "Halt" then
			stream.runtime.consumer.OnActorHalted(ActorUtils.actor(stream))
		elseif path == "Remove" then
			stream.runtime.consumer.OnActorRemoved(ActorUtils.actor(stream))
		else
			Registry.Reset()
		end

		expect(fixture.owner.GetControlledActor()).toBeNil()
		expect(fixture.owner.GetProfileSources(actor)).toEqual({})
		expect(fixture.owner.GetEffectiveRoute(actor, Utils.key())).toBeNil()

		expect(fixture.transitions[1]).toMatchObject({
			actor = actor,
			previous = { status = "Mapped" },
			next = { status = "Unmapped" },
		})

		Utils.press(fixture, 1)
		expect(Utils.actions(fixture)).toEqual({ "Combat.Punch" })
	end)
end

it("never inherits an old Actor's profiles when a new identity reuses the same ID", function()
	Utils.set(fixture, { Utils.fixed() })
	Utils.select(fixture)
	Registry.Remove(fixture.actor)
	local replacement: ActorTypes.ActorView = Utils.actor(fixture, "ActorA")
	expect(replacement).never.toBe(fixture.actor)
	expect(fixture.owner.GetControlledActor()).toBeNil()
	expect(fixture.owner.GetProfileSources(replacement)).toEqual({})
	expect(Utils.route(fixture, nil, replacement)).toEqual({ status = "Unmapped" })
	expect({ fixture.owner.SetControlledActor(fixture.actor) }).toEqual({ false, "ActorViewUnavailable" })
	Utils.select(fixture, replacement)
	Utils.press(fixture, 0)
	expect(fixture.selections).toEqual({})
end)

it("rejects public mutation inside private retirement notification with no delayed successful write", function()
	Utils.set(fixture, { Utils.fixed() })
	Utils.select(fixture)
	local results: { { any } } = {}

	local stop = fixture.owner.ObserveRoutes(function(change: Types.EffectiveRouteTransition): ()
		if change.next.status ~= "Unmapped" then
			return
		end

		table.insert(results, { fixture.owner.SetProfileSource(fixture.other, "Late", { routes = { Utils.fixed() } }) })
		table.insert(results, { fixture.owner.RemoveProfileSource(fixture.other, "Base") })
		table.insert(results, { fixture.owner.SetControlledActor(fixture.other) })
	end)

	Registry.Remove(fixture.actor)

	expect(results).toEqual({
		{ false, "DispatchInProgress" },
		{ false, "DispatchInProgress" },
		{ false, "DispatchInProgress" },
	})

	expect(fixture.owner.GetProfileSources(fixture.other)).toEqual({})
	expect(fixture.owner.GetControlledActor()).toBeNil()
	stop()
end)

it("disconnects the old owner and validator without affecting a newly installed owner", function()
	Utils.set(fixture, { Utils.fixed() })
	Utils.select(fixture)
	local old: Types.ClientActionOwner = fixture.owner
	old.Destroy()
	old.Destroy()
	fixture.owner = Owner.new(fixture.options)
	Utils.set(fixture, { Utils.fixed(nil, "New.Owner") })
	Utils.select(fixture)
	Utils.press(fixture, 0)
	expect(Utils.actions(fixture)).toEqual({ "New.Owner" })
	expect({ old.SetProfileSource(fixture.actor, "Late", { routes = {} }) }).toEqual({ false, "ClientNotReady" })
	expect({ old.SetControlledActor(fixture.actor) }).toEqual({ false, "ClientNotReady" })
	expect(old.GetControlledActor()).toBeNil()
	expect(old.GetEffectiveRoute(fixture.actor, Utils.key())).toBeNil()
	expect(old.GetProfileSources(fixture.actor)).toEqual({})
	expect({ fixture.owner.RemoveProfileSource(fixture.actor, "Base") }).toEqual({ true })
	expect({ fixture.input.input.owner.RemoveSource("Core") }).toEqual({ true })
end)

it("clears pending deadline callbacks and never hands old selections to a sink after teardown", function()
	expect({ fixture.input.input.owner.SetSource("Sequences", SequenceUtils.deferred()) }).toEqual({ true })
	Utils.set(fixture, { Utils.fixed({ kind = "Sequence", sequenceId = "Short" }) })
	Utils.select(fixture)
	SequenceUtils.play(fixture.input, { "X", "Q" })
	fixture.owner.Destroy()
	SequenceUtils.wake(fixture.input, 2)
	expect(fixture.selections).toEqual({})
	expect(fixture.owner.GetControlledActor()).toBeNil()
end)

it("rejects public mutation from private invalidation observers registered before the route owner", function()
	fixture.owner.Destroy()
	local result: { any } = {}

	local stop = Registry.ObserveInvalidation(function(actor: ActorTypes.ActorView): ()
		if actor == fixture.actor then
			result = { fixture.owner.SetControlledActor(fixture.other) }
		end
	end)

	fixture.owner = Owner.new(fixture.options)
	Utils.select(fixture)
	Registry.Remove(fixture.actor)
	expect(result).toEqual({ false, "DispatchInProgress" })
	expect(fixture.owner.GetControlledActor()).toBeNil()
	stop()
end)

it("keeps registry reset fenced during nested reset and disallows installation from a barrier callback", function()
	local result: { any } = {}

	local stop = Registry.ObserveInvalidation(function(actor: ActorTypes.ActorView): ()
		if actor == fixture.actor then
			Registry.Reset()
			result = { Registry.Install(fixture.other) }
		end
	end)

	Registry.Reset()
	expect(result).toEqual({ false, "RegistryResetInProgress" })
	expect(Registry.GetAllActorViews()).toEqual({})
	stop()
end)

it("does not deliver an invalidation observer disconnected earlier in the same barrier", function()
	local calls: number = 0
	local stopSecond: (() -> ())? = nil

	local stopFirst = Registry.ObserveInvalidation(function(): ()
		assert(stopSecond, "Expected later observer")()
	end)

	stopSecond = Registry.ObserveInvalidation(function(): ()
		calls += 1
	end)

	Registry.Remove(fixture.actor)
	expect(calls).toBe(0)
	stopFirst()
	assert(stopSecond, "Expected cleanup")()
end)
