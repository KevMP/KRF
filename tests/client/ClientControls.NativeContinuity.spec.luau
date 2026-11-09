--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local JestGlobals = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: (string, () -> ()) -> () = (JestGlobals.it :: unknown) :: (string, () -> ()) -> ()
local beforeEach: (() -> ()) -> () = (JestGlobals.beforeEach :: unknown) :: (() -> ()) -> ()
local afterEach: (() -> ()) -> () = (JestGlobals.afterEach :: unknown) :: (() -> ()) -> ()
local expect = JestGlobals.expect
local ActionUtils = require(script.Parent.Utils.ActionInputTestUtils)
local Utils = require(script.Parent.Utils.ControlTestUtils)
local fixture: Utils.Fixture

beforeEach(function()
	fixture = Utils.new()
	Utils.ready(fixture)
end)

afterEach(function()
	Utils.destroy(fixture)
end)

for _, syntheticEnd: boolean in { false, true } do
	it("retires a held Action before overlapping sink takeover without Stop " .. tostring(syntheticEnd), function()
		local core = fixture.base.input.GetGraphSnapshot().sources.Core

		local inputs = table.clone(assert(core.inputs, "Expected core definitions"))

		inputs.AbilitySlot1 = {
			context = "Combat",
			type = Enum.InputActionType.Bool,
			bindings = { Keyboard = { keyCode = Enum.KeyCode.Q } },
		}

		expect({ fixture.base.input.SetSource("Core", { contexts = core.contexts, inputs = inputs }) }).toEqual({ true })

		expect({
			fixture.base.input.SetSource("Menu", {
				contexts = { Menu = { priority = 3000, sink = true } },
				inputs = {
					Confirm = {
						context = "Menu",
						type = Enum.InputActionType.Bool,
						bindings = { Keyboard = { keyCode = Enum.KeyCode.Q } },
					},
				},
			}),
		}).toEqual({ true })

		local original: number = Utils.charge(fixture)

		fixture.onWrite = function(operation: string): ()
			if operation == "ConfigureContext:Menu" and syntheticEnd then
				ActionUtils.emit(fixture.base, "Released")
			end
		end

		Utils.apply({ contexts = { { contextId = "Menu", enabled = true } } })

		expect(ActionUtils.packets(fixture.base)[2]).toMatchObject({
			kind = "KRF.Action.Interrupt",
			originalStartRequestId = original,
		})

		expect(fixture.stopCalls).toBe(0)
		expect(fixture.events[2]).toMatchObject({ kind = "Cancelled", reason = "InputOwnershipChanged" })
		expect(#fixture.events).toBe(2)

		-- A synthetic neutral on takeover or restoration is not physical rearm.
		Utils.apply({ contexts = { { contextId = "Menu", enabled = false } } })
		fixture.onWrite = nil
		ActionUtils.emit(fixture.base, "Pressed")
		expect(Utils.kinds(fixture)).toEqual({ "KRF.Action.Start", "KRF.Action.Interrupt" })
		ActionUtils.emit(fixture.base, "Released")
		ActionUtils.emit(fixture.base, "Pressed")
		expect(Utils.kinds(fixture)).toEqual({ "KRF.Action.Start", "KRF.Action.Interrupt", "KRF.Action.Start" })
		expect(fixture.stopCalls).toBe(0)
	end)
end

it("recognizes the next press after an unaffected idle input completes a tap during Apply", function()
	ActionUtils.set(fixture.base, { ActionUtils.route("Combat.Fireball") })

	fixture.onWrite = function(): ()
		fixture.onWrite = nil
		ActionUtils.tap(fixture.base)
	end

	Utils.apply({ contexts = { { contextId = "Gate", enabled = false } } })
	expect(Utils.kinds(fixture)).toEqual({})
	expect(fixture.events).toEqual({})
	ActionUtils.tap(fixture.base)
	expect(Utils.kinds(fixture)).toEqual({ "KRF.Action.Start" })
	expect(fixture.events[1]).toMatchObject({ kind = "Pressed" })
end)
