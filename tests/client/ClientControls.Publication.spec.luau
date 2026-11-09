--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: (string, () -> ()) -> () = (JestGlobals.it :: unknown) :: (string, () -> ()) -> ()
local expect = JestGlobals.expect
local beforeEach: (() -> ()) -> () = (JestGlobals.beforeEach :: unknown) :: (() -> ()) -> ()
local afterEach: (() -> ()) -> () = (JestGlobals.afterEach :: unknown) :: (() -> ()) -> ()
local ActionTypes = require(KRF.client.Action.types)
local Runtime: ActionTypes.ClientActionRuntime = require(KRF.client.Action.ClientActionRuntime)
local ActionUtils = require(script.Parent.Utils.ActionInputTestUtils)
local Utils = require(script.Parent.Utils.ControlTestUtils)
local InputTypes = require(KRF.client.Input.types)
local NetworkingTypes = require(KRF.client.Networking.types)
local Input: InputTypes.InputRuntime = require(KRF.client.Input.InputRuntime)
local ClientTypes = require(KRF.client.types)
local Client: ClientTypes.Client = require(KRF.client)
local Controls = require(KRF.client.Controls.ClientControls)
local InputState = require(KRF.client.Input.utils.InputRuntimeState)
local originalNotify = InputState.Notify
local CommandState = require(KRF.client.Networking.utils.CommandRuntimeState)
local fixture: Utils.Fixture

beforeEach(function()
	fixture = Utils.new()
	Utils.ready(fixture)
end)

afterEach(function()
	InputState.Notify = originalNotify
	Utils.destroy(fixture)
end)

it("publishes complete input, profile, context and Actor state before private commit observers", function()
	local observations: number = 0

	local stop = fixture.base.input.ObserveConfigurationCommit(function(change: InputTypes.InputGraphChange): ()
		observations += 1
		expect(Runtime.GetControlledActor()).toBe(fixture.base.other)
		expect(fixture.base.input.GetContext("HandSigns")).toMatchObject({ enabled = true })
		expect(fixture.base.input.GetInput("Sign")).toMatchObject({ sourceId = "Manual" })

		expect(Runtime.GetEffectiveRoute(fixture.base.other, ActionUtils.key("Sign"))).toMatchObject({
			actionId = "Combat.Fireball",
		})

		expect(change.next).toBe(fixture.base.input.GetGraphSnapshot())
		expect(Utils.kinds(fixture)).toEqual({ "KRF.Action.Start" })
	end)

	Utils.charge(fixture)

	Utils.apply({
		inputs = { { kind = "Set", sourceId = "Manual", definition = Utils.manual() } },
		profiles = {
			{
				kind = "Set",
				actor = fixture.base.other,
				sourceId = "Manual",
				profile = { routes = { ActionUtils.route("Combat.Fireball", ActionUtils.key("Sign")) } },
			},
		},
		contexts = { { contextId = "HandSigns", enabled = true } },
		selection = { kind = "Set", actor = fixture.base.other },
	})

	expect(observations).toBe(1)
	expect(Utils.kinds(fixture)).toEqual({ "KRF.Action.Start", "KRF.Action.Interrupt" })
	stop()
end)

it("holds new managed Starts until original Interrupt admission after coherent publication", function()
	local original: number = Utils.charge(fixture)

	ActionUtils.set(
		fixture.base,
		{ ActionUtils.route("Combat.Fireball", ActionUtils.key("Other")) },
		fixture.base.other
	)

	local inspected: number = 0

	fixture.base.commands.beforeSend = function(): ()
		fixture.base.commands.beforeSend = nil
		inspected += 1
		expect(Runtime.GetControlledActor()).toBe(fixture.base.other)
		expect(fixture.base.input.GetContext("Gate")).toMatchObject({ enabled = false })
		ActionUtils.emit(fixture.base, "Pressed", "Other")
	end

	Utils.apply({
		selection = { kind = "Set", actor = fixture.base.other },
		contexts = { { contextId = "Gate", enabled = false } },
	})

	expect(inspected).toBe(1)

	expect(ActionUtils.packets(fixture.base)[2]).toMatchObject({
		kind = "KRF.Action.Interrupt",
		originalStartRequestId = original,
	})

	expect(#ActionUtils.packets(fixture.base)).toBe(2)
	ActionUtils.emit(fixture.base, "Released", "Other")
	ActionUtils.tap(fixture.base, "Other")

	expect(ActionUtils.packets(fixture.base)[3]).toMatchObject({
		kind = "KRF.Action.Start",
		actionId = "Combat.Fireball",
	})
end)

it("classifies disable-generated native ends as one Cancelled and never samples release aim", function()
	local original: number = Utils.charge(fixture)

	fixture.base.syntheticEnd = true
	Utils.apply({ contexts = { { contextId = "Combat", enabled = false } } })
	expect(fixture.events).toHaveLength(2)
	expect(fixture.events[2]).toMatchObject({ kind = "Cancelled", inputId = "AbilitySlot1" })
	expect(fixture.stopCalls).toBe(0)

	expect(ActionUtils.packets(fixture.base)[2]).toMatchObject({
		kind = "KRF.Action.Interrupt",
		originalStartRequestId = original,
	})

	Utils.apply({ contexts = { { contextId = "Combat", enabled = true } } })
	ActionUtils.emit(fixture.base, "Released")
	expect(fixture.stopCalls).toBe(0)
	expect(#ActionUtils.packets(fixture.base)).toBe(2)
end)

it("delivers a genuine release before Apply once and never converts its original Stop into Interrupt", function()
	local original: number = Utils.charge(fixture)
	ActionUtils.emit(fixture.base, "Released")
	Utils.apply({ selection = { kind = "Set", actor = fixture.base.other } })
	expect(fixture.stopCalls).toBe(1)
	expect(Utils.kinds(fixture)).toEqual({ "KRF.Action.Start", "KRF.Action.Stop" })
	expect(ActionUtils.packets(fixture.base)[2].originalStartRequestId).toBe(original)
end)

it("preserves a proven genuine release of an unaffected epoch during native writes", function()
	expect({
		fixture.base.input.SetSource("Tap", { gestures = { AbilitySlot1 = { Tap = { maxDurationSeconds = 0.25 } } } }),
	}).toEqual({ true })

	local original: number = Utils.charge(fixture)

	local order: { string } = {}

	local stop = fixture.base.input.ObservePrimitive("Routing", function(occurrence): ()
		if occurrence.event.kind == "Released" then
			table.insert(order, "Released")
			expect(fixture.base.input.GetContext("Gate")).toMatchObject({ enabled = false })

			expect(ActionUtils.packets(fixture.base)[2]).toMatchObject({
				kind = "KRF.Action.Stop",
				originalStartRequestId = original,
			})
		end
	end)

	local gesture = Input.OnGesture:Connect(function(): ()
		table.insert(order, "Tap")
	end)

	fixture.onWrite = function(): ()
		fixture.onWrite = nil
		ActionUtils.emit(fixture.base, "Released")
		expect(fixture.stopCalls).toBe(0)
	end

	Utils.apply({ contexts = { { contextId = "Gate", enabled = false } } })
	task.wait()
	expect(fixture.stopCalls).toBe(1)
	expect(order).toEqual({ "Released", "Tap" })
	expect(Utils.kinds(fixture)).toEqual({ "KRF.Action.Start", "KRF.Action.Stop" })
	stop()
	gesture:Disconnect()
end)

it("cancels an uncertain release from an invalidated epoch during native writes without Stop", function()
	Utils.charge(fixture)

	fixture.onWrite = function(): ()
		fixture.onWrite = nil
		ActionUtils.emit(fixture.base, "Released")
	end

	Utils.apply({ contexts = { { contextId = "Combat", enabled = false } } })
	expect(fixture.stopCalls).toBe(0)
	expect(fixture.events[2].kind).toBe("Cancelled")
	expect(Utils.kinds(fixture)).toEqual({ "KRF.Action.Start", "KRF.Action.Interrupt" })
end)

it("uses I5's bounded pending follow-up after capacity refusal and does not block Apply", function()
	local original: number = Utils.charge(fixture)
	local commands: NetworkingTypes.ClientCommandRuntime = assert(CommandState.Get())
	local send = commands._SendAdmitted
	local refusal: boolean = true
	local attempts: number = 0

	commands._SendAdmitted = function(self, id, actor, parameters, admitted, committed): (number?, string?)
		if id == "KRF.Action.Interrupt" then
			attempts += 1

			if refusal then
				return nil, "CommandPendingFull"
			end
		end

		return send(self, id, actor, parameters, admitted, committed)
	end

	Utils.apply({ selection = { kind = "Set", actor = fixture.base.other } })
	expect(attempts).toBe(1)
	expect(Utils.kinds(fixture)).toEqual({ "KRF.Action.Start" })
	-- Capacity is released by the original Start ACK, using the real N9/I5 drain.
	refusal = false
	ActionUtils.outcome(fixture.base, original, "KRF.Action.Start", "Accepted")

	expect(ActionUtils.packets(fixture.base)[2]).toMatchObject({
		kind = "KRF.Action.Interrupt",
		originalStartRequestId = original,
	})

	Utils.apply({})
	expect(#ActionUtils.packets(fixture.base)).toBe(2)
	commands._SendAdmitted = send
end)

it("does not replay an admitted Unknown Interrupt or change Apply success after later rejection", function()
	Utils.charge(fixture)
	Utils.apply({ selection = { kind = "Set", actor = fixture.base.other } })
	local interrupt: ActionUtils.Packet = ActionUtils.packets(fixture.base)[2]
	fixture.base.clock.Advance(10)
	fixture.base.clock.Advance(10)
	Utils.apply({})
	expect(#ActionUtils.packets(fixture.base)).toBe(2)
	ActionUtils.outcome(fixture.base, interrupt.requestId, "KRF.Action.Interrupt", "Rejected", "NoLongerActive")
	expect(Runtime.GetControlledActor()).toBe(fixture.base.other)
	expect(#ActionUtils.packets(fixture.base)).toBe(2)
end)

it("isolates a public publication callback fault from the committed generation", function()
	InputState.Notify = function(event: InputTypes.SemanticInputEvent): ()
		if event.kind == "Cancelled" then
			error("ConsumerObservationFault", 0)
		end
	end

	Utils.charge(fixture)
	Utils.apply({ contexts = { { contextId = "Combat", enabled = false } } })
	task.wait()
	expect(fixture.base.input.GetContext("Combat")).toMatchObject({ enabled = false })
	expect(Runtime.GetControlledActor()).toBe(fixture.base.actor)
	expect(Utils.kinds(fixture)).toEqual({ "KRF.Action.Start", "KRF.Action.Interrupt" })
end)

it("rejects a generation torn down by the original Stop producer during preserved release delivery", function()
	Utils.destroy(fixture)
	fixture = Utils.new()

	local policies: ActionTypes.ActionInputPolicies = ActionUtils.policies()

	policies["Combat.Rasengan"].stopParameters = function(): { releaseAim: number }
		Client._ResetForTests()

		return { releaseAim = 2 }
	end

	Utils.ready(fixture, policies)
	Utils.charge(fixture)

	fixture.onWrite = function(): ()
		fixture.onWrite = nil
		ActionUtils.emit(fixture.base, "Released")
	end

	expect({ Controls.Apply({ contexts = { { contextId = "Gate", enabled = false } } }) }).toEqual({
		false,
		"ClientNotReady",
	})

	expect(Runtime.GetControlledActor()).toBeNil()
	expect(fixture.base.callbacks).toEqual({})
	expect(fixture.connections).toBe(0)
	expect(Utils.kinds(fixture)).toEqual({ "KRF.Action.Start" })
end)
