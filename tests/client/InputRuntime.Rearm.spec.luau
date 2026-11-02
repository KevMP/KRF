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

type NeutralRecoveryCase = {
	name: string,
	inputType: Enum.InputActionType,
	kind: Types.NativeTransition,
	active: any,
	neutral: any,
	bindings: { [string]: Types.BindingDefinition },
}

local neutralRecoveryCases: { NeutralRecoveryCase } = {
	{
		name = "Bool",
		inputType = Enum.InputActionType.Bool,
		kind = "Pressed",
		active = true,
		neutral = false,
		bindings = { Keyboard = { keyCode = Enum.KeyCode.Q } },
	},
	{
		name = "Direction1D",
		inputType = Enum.InputActionType.Direction1D,
		kind = "StateChanged",
		active = 0.75,
		neutral = 0,
		bindings = { Gamepad = { keyCode = Enum.KeyCode.ButtonR2 } },
	},
	{
		name = "Direction2D",
		inputType = Enum.InputActionType.Direction2D,
		kind = "StateChanged",
		active = Vector2.new(0.25, 0.75),
		neutral = Vector2.zero,
		bindings = { Gamepad = { keyCode = Enum.KeyCode.Thumbstick1 } },
	},
	{
		name = "Direction3D",
		inputType = Enum.InputActionType.Direction3D,
		kind = "StateChanged",
		active = Vector3.new(0.25, 0.5, 0.75),
		neutral = Vector3.zero,
		bindings = { Keyboard = { up = Enum.KeyCode.W, down = Enum.KeyCode.S } },
	},
}

for _, case: NeutralRecoveryCase in neutralRecoveryCases do
	it(
		"accepts the first fresh " .. case.name .. " activation after re-enable confirms an unobserved neutral",
		function()
			local definition: TestUtils.CoreDefinition = TestUtils.definition(case.inputType)
			definition.inputs.Primary.bindings = case.bindings
			TestUtils.install(fixture, definition)
			TestUtils.enable(fixture)
			local occurrences: { Types.PrimitiveOccurrence } = {}

			fixture.owner.ObservePrimitive("Routing", function(occurrence: Types.PrimitiveOccurrence)
				table.insert(occurrences, occurrence)
			end)

			TestUtils.emit(fixture, case.kind, case.active)
			expect(fixture.owner.SetContextEnabled("Gameplay", false)).toBe(true)
			fixture.states[fixture.actions.Primary] = case.neutral
			TestUtils.enable(fixture)
			expect(TestUtils.kinds(fixture)).toEqual({ case.kind, "Cancelled" })
			TestUtils.emit(fixture, case.kind, case.active)
			expect(TestUtils.kinds(fixture)).toEqual({ case.kind, "Cancelled", case.kind })
			local event: Types.SemanticInputEvent = fixture.events[3]
			assert(event.kind ~= "Cancelled", "Expected a fresh activation")
			expect(event.value).toBe(case.active)

			if case.inputType == Enum.InputActionType.Bool then
				local original: Types.PrimitiveOccurrence = occurrences[1]
				local fresh: Types.PrimitiveOccurrence = occurrences[3]
				local originalEpoch: number = assert(original.pressEpochId, "Expected original Bool epoch")
				local freshEpoch: number = assert(fresh.pressEpochId, "Expected fresh Bool epoch")
				expect(freshEpoch > originalEpoch).toBe(true)
				expect(fixture.owner.IsPressEpochActive("Primary", originalEpoch, original.generation)).toBe(false)
				expect(fixture.owner.IsPressEpochActive("Primary", freshEpoch, fresh.generation)).toBe(true)
			end
		end
	)
end

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

it("does not treat an invalid Bool payload as confirmed neutral on re-enable", function()
	TestUtils.install(fixture)
	TestUtils.enable(fixture)
	TestUtils.emit(fixture, "Pressed", true)
	expect(fixture.owner.SetContextEnabled("Gameplay", false)).toBe(true)
	fixture.states[fixture.actions.Primary] = 0
	TestUtils.enable(fixture)
	TestUtils.emit(fixture, "Pressed", true)
	expect(TestUtils.kinds(fixture)).toEqual({ "Pressed", "Cancelled" })
	TestUtils.emit(fixture, "Released", false)
	TestUtils.emit(fixture, "Pressed", true)
	expect(TestUtils.kinds(fixture)).toEqual({ "Pressed", "Cancelled", "Pressed" })
end)

it("keeps the input disarmed when the native state read fails on re-enable", function()
	TestUtils.install(fixture)
	TestUtils.enable(fixture)
	TestUtils.emit(fixture, "Pressed", true)
	expect(fixture.owner.SetContextEnabled("Gameplay", false)).toBe(true)

	fixture.native.ReadState = function(_action: InputAction): any
		error("NativeStateUnavailable")
	end

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
