--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local Types = require(KRF.client.Input.types)
local TestUtils = require(script.Parent.Utils.InputTestUtils)

local fixture: TestUtils.Fixture

beforeEach(function()
	fixture = TestUtils.new()
end)

afterEach(function()
	TestUtils.destroy(fixture)
end)

it("cancels active Direction1D once and suppresses stale values until typed neutral", function()
	local definition: TestUtils.CoreDefinition = TestUtils.definition(Enum.InputActionType.Direction1D)
	definition.inputs.Primary.bindings = { Device = { keyCode = Enum.KeyCode.ButtonR2 } }
	TestUtils.install(fixture, definition)
	TestUtils.enable(fixture)
	TestUtils.emit(fixture, "StateChanged", 0.75)
	expect(fixture.owner.SetContextEnabled("Gameplay", false)).toBe(true)
	TestUtils.enable(fixture)
	TestUtils.emit(fixture, "StateChanged", 0.75)
	expect(TestUtils.kinds(fixture)).toEqual({ "StateChanged", "Cancelled" })
	TestUtils.emit(fixture, "StateChanged", 0)
	TestUtils.emit(fixture, "StateChanged", 0.75)
	expect(TestUtils.kinds(fixture)).toEqual({ "StateChanged", "Cancelled", "StateChanged" })
	expect((fixture.events[3] :: Types.ValueChange).value).toBe(0.75)
end)

it("cancels active Direction2D once and suppresses stale values until typed neutral", function()
	local definition: TestUtils.CoreDefinition = TestUtils.definition(Enum.InputActionType.Direction2D)
	definition.inputs.Primary.bindings = { Device = { keyCode = Enum.KeyCode.Thumbstick1 } }
	TestUtils.install(fixture, definition)
	TestUtils.enable(fixture)
	TestUtils.emit(fixture, "StateChanged", Vector2.new(0.4, 0.7))
	expect(fixture.owner.SetContextEnabled("Gameplay", false)).toBe(true)
	TestUtils.enable(fixture)
	TestUtils.emit(fixture, "StateChanged", Vector2.new(0.4, 0.7))
	expect(TestUtils.kinds(fixture)).toEqual({ "StateChanged", "Cancelled" })
	TestUtils.emit(fixture, "StateChanged", Vector2.zero)
	TestUtils.emit(fixture, "StateChanged", Vector2.new(0.4, 0.7))
	expect(TestUtils.kinds(fixture)).toEqual({ "StateChanged", "Cancelled", "StateChanged" })
	expect((fixture.events[3] :: Types.ValueChange).value).toBe(Vector2.new(0.4, 0.7))
end)

it("cancels active Direction3D once and suppresses stale values until typed neutral", function()
	local definition: TestUtils.CoreDefinition = TestUtils.definition(Enum.InputActionType.Direction3D)

	definition.inputs.Primary.bindings =
		{ Device = { forward = Enum.KeyCode.W, backward = Enum.KeyCode.S, up = Enum.KeyCode.E, down = Enum.KeyCode.Q } }

	TestUtils.install(fixture, definition)
	TestUtils.enable(fixture)
	TestUtils.emit(fixture, "StateChanged", Vector3.new(1, 0, -1))
	expect(fixture.owner.SetContextEnabled("Gameplay", false)).toBe(true)
	TestUtils.enable(fixture)
	TestUtils.emit(fixture, "StateChanged", Vector3.new(1, 0, -1))
	expect(TestUtils.kinds(fixture)).toEqual({ "StateChanged", "Cancelled" })
	TestUtils.emit(fixture, "StateChanged", Vector3.zero)
	TestUtils.emit(fixture, "StateChanged", Vector3.new(1, 0, -1))
	expect(TestUtils.kinds(fixture)).toEqual({ "StateChanged", "Cancelled", "StateChanged" })
	expect((fixture.events[3] :: Types.ValueChange).value).toBe(Vector3.new(1, 0, -1))
end)

it("retires the Bool epoch before a synthetic disable end and cancels exactly once", function()
	TestUtils.install(fixture)
	TestUtils.enable(fixture)
	fixture.syntheticEnd = true

	local occurrences: { Types.PrimitiveOccurrence } = {}

	fixture.owner.ObservePrimitive("Routing", function(occurrence: Types.PrimitiveOccurrence)
		table.insert(occurrences, occurrence)

		if occurrence.event.kind == "Cancelled" then
			local pressed: Types.PrimitiveOccurrence = occurrences[1]

			expect(
				fixture.owner.IsPressEpochActive(
					"Primary",
					assert(pressed.pressEpochId, "Expected Bool press epoch"),
					pressed.generation
				)
			).toBe(false)
		end
	end)

	TestUtils.emit(fixture, "Pressed", true)
	expect(fixture.owner.SetContextEnabled("Gameplay", false)).toBe(true)
	expect(fixture.owner.SetContextEnabled("Gameplay", false)).toBe(true)
	expect(TestUtils.kinds(fixture)).toEqual({ "Pressed", "Cancelled" })
	expect((fixture.events[2] :: Types.InputCancellation).reason).toBe("ContextDisabled")
	expect((fixture.events[2] :: any).value).toBeNil()
end)

it("preserves a genuine release observed before disable without adding cancellation", function()
	TestUtils.install(fixture)
	TestUtils.enable(fixture)
	TestUtils.emit(fixture, "Pressed", true)
	TestUtils.emit(fixture, "Released", false)
	fixture.syntheticEnd = true
	expect(fixture.owner.SetContextEnabled("Gameplay", false)).toBe(true)
	expect(TestUtils.kinds(fixture)).toEqual({ "Pressed", "Released" })
end)

it("does not re-press a held key on re-enable and accepts a fresh press after neutral", function()
	TestUtils.install(fixture)
	TestUtils.enable(fixture)
	TestUtils.emit(fixture, "Pressed", true)
	expect(fixture.owner.SetContextEnabled("Gameplay", false)).toBe(true)
	TestUtils.enable(fixture)
	TestUtils.emit(fixture, "Pressed", true)
	expect(TestUtils.kinds(fixture)).toEqual({ "Pressed", "Cancelled" })
	TestUtils.emit(fixture, "Released", false)
	TestUtils.emit(fixture, "Pressed", true)
	TestUtils.emit(fixture, "Released", false)
	expect(TestUtils.kinds(fixture)).toEqual({ "Pressed", "Cancelled", "Pressed", "Released" })
end)

it("recovers after a release observed while disabled without fabricating a gameplay release", function()
	TestUtils.install(fixture)
	TestUtils.enable(fixture)
	TestUtils.emit(fixture, "Pressed", true)
	expect(fixture.owner.SetContextEnabled("Gameplay", false)).toBe(true)
	TestUtils.emit(fixture, "Released", false)
	TestUtils.enable(fixture)
	TestUtils.emit(fixture, "Pressed", true)
	expect(TestUtils.kinds(fixture)).toEqual({ "Pressed", "Cancelled", "Pressed" })
end)

it("conservatively rejects an uncertain press when neutral cannot be proven", function()
	TestUtils.install(fixture)
	TestUtils.enable(fixture)
	TestUtils.emit(fixture, "Pressed", true)
	expect(fixture.owner.SetContextEnabled("Gameplay", false)).toBe(true)
	fixture.states[fixture.actions.Primary] = nil
	TestUtils.enable(fixture)
	TestUtils.emit(fixture, "Pressed", true)
	expect(TestUtils.kinds(fixture)).toEqual({ "Pressed", "Cancelled" })
	TestUtils.emit(fixture, "Released", false)
	TestUtils.emit(fixture, "Pressed", true)
	expect(TestUtils.kinds(fixture)).toEqual({ "Pressed", "Cancelled", "Pressed" })
end)

it("cancels the original active Bool on source removal and rejects stale native callbacks", function()
	TestUtils.install(fixture)
	TestUtils.enable(fixture)
	TestUtils.emit(fixture, "Pressed", true)
	local oldCallback = fixture.callbacks[fixture.actions.Primary]
	expect(fixture.owner.RemoveSource("Core")).toBe(true)
	expect(TestUtils.kinds(fixture)).toEqual({ "Pressed", "Cancelled" })
	expect((fixture.events[2] :: Types.InputCancellation).reason).toBe("SourceRemoved")
	oldCallback("Released", false)
	expect(TestUtils.kinds(fixture)).toEqual({ "Pressed", "Cancelled" })
end)

it("cancels the original active Bool on effective binding replacement and rejects stale native callbacks", function()
	TestUtils.install(fixture)
	TestUtils.enable(fixture)
	TestUtils.emit(fixture, "Pressed", true)
	local oldCallback = fixture.callbacks[fixture.actions.Primary]

	expect(
		fixture.owner.SetSource(
			"Rebind",
			{ bindingOverrides = { Primary = { Keyboard = { keyCode = Enum.KeyCode.E } } } }
		)
	).toBe(true)

	expect(TestUtils.kinds(fixture)).toEqual({ "Pressed", "Cancelled" })
	expect((fixture.events[2] :: Types.InputCancellation).reason).toBe("BindingChanged")
	oldCallback("Released", false)
	expect(TestUtils.kinds(fixture)).toEqual({ "Pressed", "Cancelled" })
end)

it("cancels the original active Bool on input type replacement and rejects stale native callbacks", function()
	TestUtils.install(fixture)
	TestUtils.enable(fixture)
	TestUtils.emit(fixture, "Pressed", true)
	local oldCallback = fixture.callbacks[fixture.actions.Primary]

	expect(fixture.owner.SetSource("Core", {
		contexts = { Gameplay = { priority = 2000, sink = true } },
		inputs = {
			Primary = {
				context = "Gameplay",
				type = Enum.InputActionType.Direction1D,
				bindings = { Gamepad = { keyCode = Enum.KeyCode.ButtonR2 } },
			},
		},
	})).toBe(true)

	expect(TestUtils.kinds(fixture)).toEqual({ "Pressed", "Cancelled" })
	expect((fixture.events[2] :: Types.InputCancellation).reason).toBe("InputChanged")
	oldCallback("Released", false)
	expect(TestUtils.kinds(fixture)).toEqual({ "Pressed", "Cancelled" })
end)
