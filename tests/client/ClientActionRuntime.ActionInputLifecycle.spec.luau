--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local Types = require(KRF.client.Action.types)
local InputTypes = require(KRF.client.Input.types)
local Runtime: Types.ClientActionRuntime = require(KRF.client.Action.ClientActionRuntime)
local Registry = require(KRF.client.Actor.utils.ActorViewRegistryState)
local ActionState = require(KRF.client.Action.utils.ClientActionRuntimeState)
local Utils = require(script.Parent.Utils.ActionInputTestUtils)
local fixture: Utils.Fixture
local policies: Types.ActionInputPolicies

beforeEach(function()
	fixture = Utils.new()
	policies = Utils.policies()
end)

afterEach(function()
	Utils.destroy(fixture)
end)

local function charge(): number
	Utils.ready(fixture, policies)
	Utils.set(fixture, { Utils.route("Combat.Rasengan") })
	Utils.emit(fixture, "Pressed")

	return Utils.started(fixture)
end

it("defaults a compatible missing policy to one Start per trigger and ignores release and invalidation", function()
	Utils.ready(fixture, nil, { ["Mode.Aura"] = { stop = {}, allowInputInterrupt = true } })
	Utils.set(fixture, { Utils.route("Mode.Aura") })
	Utils.tap(fixture)
	Utils.tap(fixture)
	expect({ Runtime.RemoveProfileSource(fixture.actor, "Base") }).toEqual({ true })

	expect(Utils.packets(fixture)).toEqual({
		{ kind = "KRF.Action.Start", requestId = 1, actionId = "Mode.Aura" },
		{ kind = "KRF.Action.Start", requestId = 2, actionId = "Mode.Aura" },
	})
end)

it("sends Start once for a live press and one original-receipt Stop for duplicate releases before ACK", function()
	local original: number = charge()
	Utils.emit(fixture, "Pressed")
	Utils.emit(fixture, "Released")
	Utils.emit(fixture, "Released")

	expect(Utils.packets(fixture)).toEqual({
		{ kind = "KRF.Action.Start", requestId = original, actionId = "Combat.Rasengan", parameters = { aim = 1 } },
		{
			kind = "KRF.Action.Stop",
			requestId = 2,
			originalStartRequestId = original,
			actionId = "Combat.Rasengan",
			parameters = { releaseAim = 2 },
		},
	})
end)

it("keeps original Rasengan policy when equipment changes behind an unchanged dynamic slot", function()
	local equipped: string = "Combat.Rasengan"
	local aim: number = 1
	local resolutions: number = 0
	local stopCalls: number = 0
	local stoppedContext: Types.ActionInputContext? = nil

	policies["Combat.Rasengan"].stopParameters = function(context): any
		stopCalls += 1
		stoppedContext = context

		return { releaseAim = aim }
	end

	policies["Combat.Fireball"].startParameters = function(): any
		return { aim = aim }
	end

	Utils.ready(fixture, policies)

	local route: Types.ActionRoute = {
		when = Utils.key(),
		target = {
			kind = "Dynamic",
			resolve = function(): Types.ResolvedAction
				resolutions += 1

				return { actionId = equipped }
			end,
		},
	}

	Utils.set(fixture, { route })
	Utils.emit(fixture, "Pressed")
	local original: number = Utils.started(fixture)
	equipped = "Combat.Fireball"
	aim = 8
	Utils.set(fixture, { route })
	expect(#Utils.packets(fixture)).toBe(1)
	expect(resolutions).toBe(1)
	Utils.emit(fixture, "Released")

	expect(Utils.packets(fixture)[2]).toEqual({
		kind = "KRF.Action.Stop",
		requestId = 2,
		originalStartRequestId = original,
		actionId = "Combat.Rasengan",
		parameters = { releaseAim = 8 },
	})

	local context: Types.ActionInputContext = assert(stoppedContext, "Original Stop producer must run")
	expect(table.isfrozen(context)).toBe(true)
	expect(context.actor).toBe(fixture.actor)
	expect(context.actionId).toBe("Combat.Rasengan")
	expect(context.originalStartRequestId).toBe(original)
	expect(context.routeKey).toEqual(Utils.key())
	Utils.tap(fixture)

	expect(Utils.packets(fixture)[3]).toMatchObject({
		kind = "KRF.Action.Start",
		actionId = "Combat.Fireball",
		parameters = { aim = 8 },
	})

	expect({ #Utils.packets(fixture), resolutions, stopCalls }).toEqual({ 3, 2, 1 })
end)

it("owns copied policy fields and callback references after initialization", function()
	local original: number = charge()

	policies["Combat.Rasengan"].activation = "OneShot"
	policies["Combat.Rasengan"].onInvalidation = "Keep"

	policies["Combat.Rasengan"].stopParameters = function(): any
		error("Mutated policy must never replace captured callbacks", 0)
	end

	policies["Combat.Rasengan"] = nil
	Utils.emit(fixture, "Released")

	expect(Utils.packets(fixture)[2]).toMatchObject({
		kind = "KRF.Action.Stop",
		originalStartRequestId = original,
		parameters = { releaseAim = 2 },
	})

	Utils.tap(fixture)
	expect(#Utils.packets(fixture)).toBe(4)
end)

it("applies the same concrete Action policy to two distinct fixed routes with independent epochs", function()
	Utils.ready(fixture, policies)
	Utils.set(fixture, { Utils.route("Combat.Rasengan"), Utils.route("Combat.Rasengan", Utils.key("Other")) })
	Utils.emit(fixture, "Pressed")
	Utils.started(fixture)
	Utils.emit(fixture, "Pressed", "Other")
	Utils.emit(fixture, "Released", "Other")
	Utils.emit(fixture, "Released")
	local packets: { Utils.Packet } = Utils.packets(fixture)
	expect(#packets).toBe(4)
	expect(packets[3]).toMatchObject({ kind = "KRF.Action.Stop", originalStartRequestId = 2 })
	expect(packets[4]).toMatchObject({ kind = "KRF.Action.Stop", originalStartRequestId = 1 })
end)

for _, invalidation: string in
	{
		"RouteRemoval",
		"ShadowReplacement",
		"ContextDisable",
		"GateLoss",
		"BindingReplacement",
		"FocusLost",
		"ActorSwitch",
		"ActorRemoval",
		"ActorHalt",
	}
do
	it("uses original Interrupt without a release producer on " .. invalidation, function()
		local stopCalls: number = 0

		policies["Combat.Rasengan"].stopParameters = function(): any
			stopCalls += 1

			return { releaseAim = 2 }
		end

		Utils.ready(fixture, policies)

		local equipped: string = "Combat.Rasengan"
		local resolverCalls: number = 0

		local route: Types.ActionRoute = {
			when = Utils.key(),
			target = {
				kind = "Dynamic",
				resolve = function(): Types.ResolvedAction
					resolverCalls += 1

					return { actionId = equipped }
				end,
			},
		}

		route.requiredContexts = { "Gate" }
		Utils.set(fixture, { route })
		Utils.emit(fixture, "Pressed")
		local original: number = Utils.started(fixture)
		equipped = "Combat.Fireball"
		local sentInsideFence: boolean = false

		fixture.commands.beforeSend = function(): ()
			sentInsideFence = sentInsideFence or fixture.input.GetCommitContext() ~= nil
		end

		if invalidation == "RouteRemoval" then
			expect({ Runtime.RemoveProfileSource(fixture.actor, "Base") }).toEqual({ true })
		elseif invalidation == "ShadowReplacement" then
			expect({
				Runtime.SetProfileSource(
					fixture.actor,
					"Overlay",
					{ priority = 10, routes = { Utils.route("Combat.Fireball") } }
				),
			}).toEqual({ true })
		elseif invalidation == "ContextDisable" then
			fixture.syntheticEnd = true
			expect({ fixture.input.SetContextEnabled("Combat", false) }).toEqual({ true })
		elseif invalidation == "GateLoss" then
			expect({ fixture.input.SetContextEnabled("Gate", false) }).toEqual({ true })
		elseif invalidation == "BindingReplacement" then
			-- The input source stays defined; changing its native action type/definition cancels the epoch.
			local definition: InputTypes.InputDefinition = {
				context = "Combat",
				type = Enum.InputActionType.Bool,
				bindings = { Keyboard = { keyCode = Enum.KeyCode.Q } },
			}

			local inputs: { [string]: InputTypes.InputDefinition } = {}

			for id, action in fixture.actions do
				inputs[id] = if id == "AbilitySlot1"
					then definition
					else { context = "Combat", type = action.Type, bindings = {} }
			end

			expect({
				fixture.input.SetSource("Core", {
					contexts = { Combat = { priority = 2000, sink = true }, Gate = { priority = 1, sink = false } },
					inputs = inputs,
				}),
			}).toEqual({ true })
		elseif invalidation == "FocusLost" then
			local plan: InputTypes.PreparedInputInvalidation =
				assert(fixture.input.PrepareEpochInvalidation("FocusLost"))

			expect({ fixture.input.CommitEpochInvalidation(plan, function() end) }).toEqual({ true })
		elseif invalidation == "ActorSwitch" then
			expect({ Runtime.SetControlledActor(fixture.other) }).toEqual({ true })
		elseif invalidation == "ActorHalt" then
			Registry.Invalidate(fixture.actor, "ActorUnavailable")
		else
			Registry.Remove(fixture.actor)
		end

		expect(stopCalls).toBe(0)
		expect(resolverCalls).toBe(1)
		expect(sentInsideFence).toBe(false)
		expect(#Utils.packets(fixture)).toBe(2)

		expect(Utils.packets(fixture)[2]).toMatchObject({
			kind = "KRF.Action.Interrupt",
			originalStartRequestId = original,
			actionId = "Combat.Rasengan",
		})
	end)
end

it("preserves the old activation after a failed profile preflight", function()
	local original: number = charge()

	expect({
		Runtime.SetProfileSource(
			fixture.actor,
			"Bad",
			{ priority = 10, routes = { Utils.route("Combat.Fireball", Utils.key("Missing")) } }
		),
	}).toEqual({ false, "UnknownRouteInput" })

	expect(#Utils.packets(fixture)).toBe(1)
	Utils.emit(fixture, "Released")
	expect(Utils.packets(fixture)[2]).toMatchObject({ kind = "KRF.Action.Stop", originalStartRequestId = original })
end)

it("prepares Actor retirement without sends and interrupts only after coherent selection publication", function()
	local original: number = charge()
	local owner: Types.ClientActionOwner = assert(ActionState.Get())
	local plan: Types.PreparedActorSwitch = assert(owner.PrepareControlledActor(fixture.other))
	expect(#Utils.packets(fixture)).toBe(1)
	local observedActor = nil :: typeof(fixture.actor)?
	local fenced: boolean? = nil

	fixture.commands.beforeSend = function(): ()
		observedActor = Runtime.GetControlledActor()
		fenced = fixture.input.GetCommitContext() ~= nil
	end

	expect({ owner.CommitControlledActor(plan) }).toEqual({ true })
	expect(observedActor).toBe(fixture.other)
	expect(fenced).toBe(false)
	expect(Utils.packets(fixture)[2]).toMatchObject({ kind = "KRF.Action.Interrupt", originalStartRequestId = original })
end)

it("detaches explicit Keep on route invalidation and never reattaches the old press on reinstall", function()
	policies["Combat.Rasengan"].onInvalidation = "Keep"
	charge()
	expect({ Runtime.RemoveProfileSource(fixture.actor, "Base") }).toEqual({ true })
	Utils.set(fixture, { Utils.route("Combat.Rasengan") })
	Utils.emit(fixture, "Released")
	expect(#Utils.packets(fixture)).toBe(1)
	Utils.tap(fixture)
	expect(Utils.packets(fixture)[3]).toMatchObject({ kind = "KRF.Action.Stop", originalStartRequestId = 2 })
end)

it("rejects a prepared Actor switch after release changes its automatic activation revision", function()
	charge()
	local owner: Types.ClientActionOwner = assert(ActionState.Get())
	local plan: Types.PreparedActorSwitch = assert(owner.PrepareControlledActor(fixture.other))
	Utils.emit(fixture, "Released")
	expect(#Utils.packets(fixture)).toBe(2)
	expect({ owner.CommitControlledActor(plan) }).toEqual({ false, "StaleActorSwitch" })
	expect(Runtime.GetControlledActor()).toBe(fixture.actor)
end)

it("retains unaffected held routes when a different route loses its required context", function()
	Utils.ready(fixture, policies)

	local gated: Types.ActionRoute = Utils.route("Combat.Rasengan")
	gated.requiredContexts = { "Gate" }
	Utils.set(fixture, { gated, Utils.route("Movement.Sprint", Utils.key("Other")) })
	Utils.emit(fixture, "Pressed")
	Utils.started(fixture)
	Utils.emit(fixture, "Pressed", "Other")
	expect({ fixture.input.SetContextEnabled("Gate", false) }).toEqual({ true })
	Utils.emit(fixture, "Released", "Other")
	expect(Utils.packets(fixture)[3]).toMatchObject({ kind = "KRF.Action.Interrupt", originalStartRequestId = 1 })
	expect(Utils.packets(fixture)[4]).toMatchObject({ kind = "KRF.Action.Stop", originalStartRequestId = 2 })
end)
