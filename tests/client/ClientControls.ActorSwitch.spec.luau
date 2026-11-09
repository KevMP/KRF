--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: (string, () -> ()) -> () = (JestGlobals.it :: unknown) :: (string, () -> ()) -> ()
local expect = JestGlobals.expect
local beforeEach: (() -> ()) -> () = (JestGlobals.beforeEach :: unknown) :: (() -> ()) -> ()
local afterEach: (() -> ()) -> () = (JestGlobals.afterEach :: unknown) :: (() -> ()) -> ()
local Types = require(KRF.client.Controls.types)
local Controls: Types.ClientControls = require(KRF.client.Controls.ClientControls)
local ActionTypes = require(KRF.client.Action.types)
local Runtime: ActionTypes.ClientActionRuntime = require(KRF.client.Action.ClientActionRuntime)
local ActionUtils = require(script.Parent.Utils.ActionInputTestUtils)
local Utils = require(script.Parent.Utils.ControlTestUtils)
local ActorTypes = require(KRF.client.Actor.types)
local ClientTypes = require(KRF.client.types)
local Client: ClientTypes.Client = require(KRF.client)
local Actor = require(KRF.client.Actor.ActorView)
local Registry = require(KRF.client.Actor.utils.ActorViewRegistryState)
local ActionState = require(KRF.client.Action.utils.ClientActionRuntimeState)
local fixture: Utils.Fixture

beforeEach(function()
	fixture = Utils.new()
	Utils.ready(fixture)
end)

afterEach(function()
	Utils.destroy(fixture)
end)

for _, target: string in { "Other", "Nil" } do
	it("retires A's original WhileDown on A to " .. target .. " without Stop and requires neutral/new press", function()
		local original: number = Utils.charge(fixture)
		ActionUtils.set(fixture.base, { ActionUtils.route("Combat.Fireball") }, fixture.base.other)
		Utils.apply({ selection = { kind = "Set", actor = if target == "Other" then fixture.base.other else nil } })
		expect(Runtime.GetControlledActor()).toBe(if target == "Other" then fixture.base.other else nil)

		expect(ActionUtils.packets(fixture.base)[2]).toMatchObject({
			kind = "KRF.Action.Interrupt",
			originalStartRequestId = original,
			actionId = "Combat.Rasengan",
		})

		expect(fixture.stopCalls).toBe(0)
		ActionUtils.emit(fixture.base, "Pressed")
		expect(#ActionUtils.packets(fixture.base)).toBe(2)

		if target == "Nil" then
			Utils.apply({ selection = { kind = "Set", actor = fixture.base.other } })
		end

		ActionUtils.emit(fixture.base, "Released")
		expect(fixture.stopCalls).toBe(0)
		ActionUtils.tap(fixture.base)

		expect(ActionUtils.packets(fixture.base)[3]).toMatchObject({
			kind = "KRF.Action.Start",
			actionId = "Combat.Fireball",
		})
	end)
end

it("preserves a captured Toggle Keep on Actor switch without Stop, Interrupt or later retarget", function()
	ActionUtils.set(fixture.base, { ActionUtils.route("Mode.Aura") })
	ActionUtils.tap(fixture.base)
	expect(ActionUtils.started(fixture.base, "Mode.Aura")).toBe(1)
	Utils.apply({ selection = { kind = "Set", actor = fixture.base.other } })
	expect(Utils.kinds(fixture)).toEqual({ "KRF.Action.Start" })
	Utils.apply({ selection = { kind = "Set", actor = fixture.base.actor } })
	ActionUtils.tap(fixture.base)
	expect(Utils.kinds(fixture)).toEqual({ "KRF.Action.Start", "KRF.Action.Start" })
end)

for _, phase: string in { "BeforePrepare", "Validator", "NativeWrite" } do
	it("cannot publish an ActorView removed at " .. phase, function()
		local original: number = Utils.charge(fixture)
		local disconnect: (() -> ())? = nil

		if phase == "BeforePrepare" then
			Registry.Remove(fixture.base.other)
		elseif phase == "Validator" then
			disconnect = fixture.base.input.RegisterGraphValidator(function(): (boolean, string?)
				Registry.Remove(fixture.base.other)

				return true, nil
			end)
		else
			fixture.onWrite = function(): ()
				fixture.onWrite = nil
				Registry.Remove(fixture.base.other)
			end
		end

		local success: boolean, reason: string? = Controls.Apply({
			selection = { kind = "Set", actor = fixture.base.other },
			inputs = { { kind = "Set", sourceId = "Manual", definition = Utils.manual() } },
		})

		expect(success).toBe(false)

		if phase ~= "NativeWrite" then
			expect(reason).toBe("ActorViewUnavailable")
			expect(Runtime.GetControlledActor()).toBe(fixture.base.actor)
			expect(Utils.kinds(fixture)).toEqual({ "KRF.Action.Start" })
			ActionUtils.emit(fixture.base, "Released")

			expect(ActionUtils.packets(fixture.base)[2]).toMatchObject({
				kind = "KRF.Action.Stop",
				originalStartRequestId = original,
			})
		else
			expect(reason).toBe("ActorSwitchCommitFailed")
			expect(Runtime.GetControlledActor()).toBeNil()
			expect(fixture.stopCalls).toBe(0)
		end

		if disconnect ~= nil then
			(disconnect :: () -> ())()
		end
	end)
end

it("does not use a retired view when a new view reuses the same Actor ID", function()
	local old: ActorTypes.ActorView = fixture.base.other
	local owner: ActorTypes.ActorViewOwner = assert(Actor.new(old:GetId(), nil, {}))
	Registry.Remove(old)
	expect({ Registry.Install(owner.view) }).toEqual({ true })
	expect({ Controls.Apply({ selection = { kind = "Set", actor = old } }) }).toEqual({ false, "ActorViewUnavailable" })
	Utils.apply({ selection = { kind = "Set", actor = owner.view } })
	expect(Runtime.GetControlledActor()).toBe(owner.view)
	expect(Runtime.GetProfileSources(owner.view)).toEqual({})
	Registry.Remove(owner.view)
	owner:Destroy()
end)

it("rejects a candidate generation invalidated by reset during prospective validation", function()
	local stop = fixture.base.input.RegisterGraphValidator(function(): (boolean, string?)
		Client._ResetForTests()

		return true, nil
	end)

	local success: boolean = Controls.Apply({
		selection = { kind = "Set", actor = fixture.base.other },
		inputs = { { kind = "Set", sourceId = "Manual", definition = Utils.manual() } },
	})

	expect(success).toBe(false)
	expect(Runtime.GetControlledActor() == nil).toBe(true)
	expect({ Controls.Apply({}) }).toEqual({ false, "ClientNotReady" })
	expect(#fixture.base.container:GetDescendants()).toBe(0)
	stop()
end)

it("uses I4's prepared Actor switch preguard and preserves old control on guard rejection", function()
	Utils.charge(fixture)
	local owner: ActionTypes.ClientActionOwner = assert(ActionState.Get())
	local originalPrepare = owner.PrepareControlledActor
	local prepares: number = 0

	owner.PrepareControlledActor = function(): (ActionTypes.PreparedActorSwitch?, string?)
		prepares += 1

		return nil, "ActorSwitchGuardFailed"
	end

	expect({ Controls.Apply({ selection = { kind = "Set", actor = fixture.base.other } }) }).toEqual({
		false,
		"ActorSwitchGuardFailed",
	})

	owner.PrepareControlledActor = originalPrepare
	expect(prepares).toBe(1)
	expect(Runtime.GetControlledActor()).toBe(fixture.base.actor)
	expect(Utils.kinds(fixture)).toEqual({ "KRF.Action.Start" })
end)
