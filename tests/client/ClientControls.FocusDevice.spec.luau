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
local ClientTypes = require(KRF.client.types)
local InputTypes = require(KRF.client.Input.types)
local Client: ClientTypes.Client = require(KRF.client)
local fixture: Utils.Fixture

beforeEach(function()
	fixture = Utils.new()
	Utils.ready(fixture)
end)

afterEach(function()
	Utils.destroy(fixture)
end)

for _, kind: "FocusLost" | "DeviceDisconnected" in { "FocusLost", "DeviceDisconnected" } do
	it("retires original activations and recognition on " .. kind .. " without a gameplay release", function()
		local original: number = Utils.charge(fixture)

		expect({
			fixture.base.input.SetSource(
				"Recognition",
				{ sequences = { Pair = { steps = { "X", "Q" }, maxGapSeconds = 1, maxTotalSeconds = 2 } } }
			),
		}).toEqual({ true })

		ActionUtils.tap(fixture.base, "X")

		Utils.loss(
			fixture,
			if kind == "FocusLost"
				then { kind = "FocusLost" } :: Types.ControlLifecycleEvent
				else {
					kind = "DeviceDisconnected",
					device = Enum.UserInputType.Gamepad1,
				} :: Types.ControlLifecycleEvent
		)

		expect(fixture.stopCalls).toBe(0)

		expect(ActionUtils.packets(fixture.base)[2]).toMatchObject({
			kind = "KRF.Action.Interrupt",
			originalStartRequestId = original,
		})

		expect(fixture.events[#fixture.events].kind).toBe("Cancelled")

		Utils.loss(
			fixture,
			if kind == "FocusLost"
				then { kind = "FocusGained" }
				else { kind = "DeviceConnected", device = Enum.UserInputType.Gamepad1 }
		)

		ActionUtils.emit(fixture.base, "Pressed")
		expect(#ActionUtils.packets(fixture.base)).toBe(2)
		ActionUtils.emit(fixture.base, "Released")
		expect(fixture.stopCalls).toBe(0)
		ActionUtils.emit(fixture.base, "Pressed")
		expect(#ActionUtils.packets(fixture.base)).toBe(3)
		ActionUtils.emit(fixture.base, "Released")
		expect(#ActionUtils.packets(fixture.base)).toBe(4)
		expect(ActionUtils.packets(fixture.base)[4].kind).toBe("KRF.Action.Stop")
		expect(fixture.stopCalls).toBe(1)
	end)
end

for _, phase: string in { "Preflight", "NativeWrite", "FollowUpDrain" } do
	it("coalesces mandatory focus loss at " .. phase .. " before reopening managed Starts", function()
		Utils.charge(fixture)

		ActionUtils.set(
			fixture.base,
			{ ActionUtils.route("Movement.Sprint", ActionUtils.key("Other")) },
			fixture.base.other
		)

		local forced: number = 0

		local function lose(): ()
			forced += 1
			Utils.loss(fixture, { kind = "FocusLost" })
			Utils.loss(fixture, { kind = "FocusLost" })
			ActionUtils.emit(fixture.base, "Pressed", "Other")
		end

		local stop: (() -> ())? = nil

		if phase == "Preflight" then
			stop = fixture.base.input.RegisterGraphValidator(function(): (boolean, string?)
				if forced == 0 then
					lose()
				end

				return true, nil
			end)
		elseif phase == "NativeWrite" then
			fixture.onWrite = function(): ()
				fixture.onWrite = nil
				lose()
			end
		else
			fixture.base.commands.beforeSend = function(): ()
				fixture.base.commands.beforeSend = nil
				lose()
			end
		end

		Utils.apply({
			selection = { kind = "Set", actor = fixture.base.other },
			contexts = { { contextId = "Gate", enabled = false } },
		})

		expect(forced).toBe(1)
		expect(Utils.kinds(fixture)).toEqual({ "KRF.Action.Start", "KRF.Action.Interrupt" })
		expect(fixture.stopCalls).toBe(0)
		Utils.loss(fixture, { kind = "FocusGained" })
		ActionUtils.emit(fixture.base, "Pressed", "Other")
		expect(#ActionUtils.packets(fixture.base)).toBe(2)
		ActionUtils.emit(fixture.base, "Released", "Other")
		ActionUtils.tap(fixture.base, "Other")
		expect(ActionUtils.packets(fixture.base)[3]).toMatchObject({ actionId = "Movement.Sprint" })

		if stop ~= nil then
			(stop :: () -> ())()
		end
	end)
end

it("drains mandatory focus loss even when the proposed configuration rejects", function()
	local original: number = Utils.charge(fixture)

	local stop = fixture.base.input.RegisterGraphValidator(function(): (boolean, string?)
		Utils.loss(fixture, { kind = "FocusLost" })

		return false, "InjectedGraphRejection"
	end)

	expect({ Controls.Apply({ contexts = { { contextId = "Gate", enabled = false } } }) }).toEqual({
		false,
		"InjectedGraphRejection",
	})

	expect(fixture.base.input.GetContext("Gate")).toMatchObject({ enabled = true })

	expect(ActionUtils.packets(fixture.base)[2]).toMatchObject({
		kind = "KRF.Action.Interrupt",
		originalStartRequestId = original,
	})

	expect(fixture.stopCalls).toBe(0)
	stop()
end)

it("requires directional neutral after focus recovery and never invents Bool transitions", function()
	ActionUtils.emit(fixture.base, "StateChanged", "Axis", 0.75)
	Utils.loss(fixture, { kind = "FocusLost" })
	Utils.loss(fixture, { kind = "FocusGained" })
	local events: number = #fixture.events
	expect(fixture.events[events]).toMatchObject({ inputId = "Axis", kind = "Cancelled" })
	ActionUtils.emit(fixture.base, "StateChanged", "Axis", 0.75)
	expect(#fixture.events).toBe(events)
	ActionUtils.emit(fixture.base, "StateChanged", "Axis", 0)
	ActionUtils.emit(fixture.base, "StateChanged", "Axis", 0.75)
	expect(#fixture.events).toBe(events + 1)
	expect(fixture.events[events + 1]).toMatchObject({ inputId = "Axis", kind = "StateChanged", value = 0.75 })
	expect(ActionUtils.packets(fixture.base)).toEqual({})
end)

it("keeps a provably keyboard-only press live across an unrelated gamepad disconnect", function()
	local definition: InputTypes.InputSourceDefinition = {
		inputs = {
			KeyboardOnly = {
				context = "Combat",
				type = Enum.InputActionType.Bool,
				bindings = { Keyboard = { keyCode = Enum.KeyCode.Q } },
			},
			GamepadOnly = {
				context = "Combat",
				type = Enum.InputActionType.Bool,
				bindings = { Gamepad = { keyCode = Enum.KeyCode.ButtonR2 } },
			},
		},
	}

	expect({ fixture.base.input.SetSource("Devices", definition) }).toEqual({ true })

	ActionUtils.set(fixture.base, { ActionUtils.route("Combat.Rasengan", ActionUtils.key("KeyboardOnly")) })
	ActionUtils.emit(fixture.base, "Pressed", "KeyboardOnly")
	ActionUtils.emit(fixture.base, "Pressed", "GamepadOnly")
	Utils.loss(fixture, { kind = "DeviceDisconnected", device = Enum.UserInputType.Gamepad1 })
	expect(fixture.events[#fixture.events]).toMatchObject({ kind = "Cancelled", inputId = "GamepadOnly" })
	expect(Utils.kinds(fixture)).toEqual({ "KRF.Action.Start" })
	ActionUtils.emit(fixture.base, "Released", "KeyboardOnly")
	expect(fixture.stopCalls).toBe(1)
	expect(Utils.kinds(fixture)).toEqual({ "KRF.Action.Start", "KRF.Action.Stop" })
end)

it("resets partial sequence and Held recognition on focus loss without reviving old deadlines", function()
	expect({
		fixture.base.input.SetSource("Recognition", {
			gestures = { X = { Held = { afterSeconds = 0.25 } } },
			sequences = { Pair = { steps = { "X", "Q" }, maxGapSeconds = 1, maxTotalSeconds = 2 } },
		}),
	}).toEqual({ true })

	ActionUtils.set(fixture.base, {
		ActionUtils.route("Combat.Fireball", ActionUtils.key("X", "Held")),
		ActionUtils.route("Combat.Fireball", { kind = "Sequence", sequenceId = "Pair" }),
	})

	ActionUtils.emit(fixture.base, "Pressed", "X")
	Utils.loss(fixture, { kind = "FocusLost" })
	Utils.loss(fixture, { kind = "FocusGained" })
	fixture.base.clock.Advance(0.5)
	ActionUtils.tap(fixture.base, "Q")
	expect(ActionUtils.packets(fixture.base)).toEqual({})
	ActionUtils.emit(fixture.base, "Released", "X")
	ActionUtils.tap(fixture.base, "X")
	ActionUtils.tap(fixture.base, "Q")
	expect(Utils.kinds(fixture)).toEqual({ "KRF.Action.Start" })
end)

for _, cause: "FocusLost" | "DeviceDisconnected" in { "FocusLost", "DeviceDisconnected" } do
	it("does not rearm from background transitions while " .. cause .. " remains unavailable", function()
		Utils.charge(fixture)

		Utils.loss(
			fixture,
			if cause == "FocusLost"
				then { kind = "FocusLost" }
				else { kind = "DeviceDisconnected", device = Enum.UserInputType.Gamepad1 }
		)

		ActionUtils.emit(fixture.base, "Released")
		ActionUtils.emit(fixture.base, "Pressed")
		expect(Utils.kinds(fixture)).toEqual({ "KRF.Action.Start", "KRF.Action.Interrupt" })

		Utils.loss(
			fixture,
			if cause == "FocusLost"
				then { kind = "FocusGained" }
				else { kind = "DeviceConnected", device = Enum.UserInputType.Gamepad1 }
		)

		ActionUtils.emit(fixture.base, "Pressed")
		expect(#ActionUtils.packets(fixture.base)).toBe(2)
		ActionUtils.emit(fixture.base, "Released")
		ActionUtils.emit(fixture.base, "Pressed")

		expect(ActionUtils.packets(fixture.base)[3]).toMatchObject({
			kind = "KRF.Action.Start",
			actionId = "Combat.Rasengan",
		})

		expect(fixture.stopCalls).toBe(0)
	end)
end

it("defers ordinary idle work under a native commit and refuses bounded queue overflow", function()
	local completed: number = 0
	local refused: number = 0

	fixture.onWrite = function(): ()
		fixture.onWrite = nil

		for _ = 1, 65 do
			local accepted: boolean, reason: string? = fixture.base.input.WhenIdle(function(): ()
				completed += 1
			end)

			if not accepted then
				refused += 1
				expect(reason).toBe("InputMutationQueueLimitExceeded")
			end
		end

		expect(completed).toBe(0)
	end

	expect({ fixture.base.input.SetSource("Manual", Utils.manual()) }).toEqual({ true })
	expect(completed).toBe(64)
	expect(refused).toBe(1)
end)

it("disconnects one lifecycle subscription on reset and ignores its stale generation callback", function()
	expect(fixture.connections).toBe(1)
	local callback: (Types.ControlLifecycleEvent) -> () = fixture.lifecycle[1]
	Utils.charge(fixture)
	Client._ResetForTests()
	expect(fixture.connections).toBe(0)
	local packets: number = #ActionUtils.packets(fixture.base)
	callback({ kind = "FocusLost" })
	callback({ kind = "DeviceDisconnected", device = Enum.UserInputType.Gamepad1 })
	expect(#ActionUtils.packets(fixture.base)).toBe(packets)
	expect(Runtime.GetControlledActor()).toBeNil()
	expect({ Controls.Apply({}) }).toEqual({ false, "ClientNotReady" })
end)

it("coalesces duplicate disconnects and handles focus loss with no installed input graph", function()
	Utils.charge(fixture)
	Utils.loss(fixture, { kind = "DeviceDisconnected", device = Enum.UserInputType.Gamepad1 })
	Utils.loss(fixture, { kind = "DeviceDisconnected", device = Enum.UserInputType.Gamepad1 })
	expect(Utils.kinds(fixture)).toEqual({ "KRF.Action.Start", "KRF.Action.Interrupt" })
	Utils.loss(fixture, { kind = "DeviceConnected", device = Enum.UserInputType.Gamepad1 })

	Utils.apply({
		profiles = { { kind = "Remove", actor = fixture.base.actor, sourceId = "Base" } },
		inputs = { { kind = "Remove", sourceId = "Core" } },
	})

	local before: number = #fixture.events
	Utils.loss(fixture, { kind = "FocusLost" })
	expect(#fixture.events).toBe(before)
	expect(fixture.base.input.GetGraphSnapshot().inputs).toEqual({})
end)
