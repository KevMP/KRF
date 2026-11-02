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

it("emits one Bool transition despite native StateChanged and duplicate edge notifications", function()
	TestUtils.install(fixture)
	TestUtils.enable(fixture)
	TestUtils.emit(fixture, "Pressed", true)
	TestUtils.emit(fixture, "StateChanged", true)
	TestUtils.emit(fixture, "Pressed", true)
	TestUtils.emit(fixture, "Released", false)
	TestUtils.emit(fixture, "StateChanged", false)
	TestUtils.emit(fixture, "Released", false)
	expect(TestUtils.kinds(fixture)).toEqual({ "Pressed", "Released" })

	expect(fixture.events[1]).toEqual({
		kind = "Pressed",
		inputId = "Primary",
		contextId = "Gameplay",
		inputType = Enum.InputActionType.Bool,
		value = true,
		timestamp = 10,
		ordinal = 1,
	})

	expect((fixture.events[2] :: Types.BoolTransition).value).toBe(false)
	expect((fixture.events[1] :: any).pressEpochId).toBeNil()
	expect((fixture.events[1] :: any).reason).toBeNil()
	expect(table.isfrozen(fixture.events[1])).toBe(true)
end)

it("assigns strictly increasing ordinals and nondecreasing local dispatch time across clock regression", function()
	TestUtils.install(fixture)
	TestUtils.enable(fixture)
	TestUtils.emit(fixture, "Pressed", true)
	fixture.now = 9
	TestUtils.emit(fixture, "Released", false)
	fixture.now = 12
	TestUtils.emit(fixture, "Pressed", true)
	expect({ fixture.events[1].ordinal, fixture.events[2].ordinal, fixture.events[3].ordinal }).toEqual({ 1, 2, 3 })

	expect({ fixture.events[1].timestamp, fixture.events[2].timestamp, fixture.events[3].timestamp }).toEqual({
		10,
		10,
		12,
	})
end)

it("ignores native events while the context is disabled", function()
	TestUtils.install(fixture)
	TestUtils.emit(fixture, "Pressed", true)
	TestUtils.emit(fixture, "StateChanged", true)
	expect(#fixture.events).toBe(0)
end)

it("emits changed Direction1D values and real typed neutral without Bool edges", function()
	local definition: TestUtils.CoreDefinition = TestUtils.definition(Enum.InputActionType.Direction1D)
	definition.inputs.Primary.bindings = { Device = { keyCode = Enum.KeyCode.ButtonR2 } }
	TestUtils.install(fixture, definition)
	TestUtils.enable(fixture)
	TestUtils.emit(fixture, "StateChanged", 0.75)
	TestUtils.emit(fixture, "StateChanged", 0.75)
	TestUtils.emit(fixture, "Pressed", true)
	TestUtils.emit(fixture, "Released", false)
	TestUtils.emit(fixture, "StateChanged", 0)
	expect(TestUtils.kinds(fixture)).toEqual({ "StateChanged", "StateChanged" })
	expect((fixture.events[1] :: Types.ValueChange).value).toBe(0.75)
	expect((fixture.events[2] :: Types.ValueChange).value).toBe(0)
	expect(fixture.owner.SetContextEnabled("Gameplay", false)).toBe(true)
	expect(#fixture.events).toBe(2)
end)

it("emits changed Direction2D values and real typed neutral without Bool edges", function()
	local definition: TestUtils.CoreDefinition = TestUtils.definition(Enum.InputActionType.Direction2D)
	definition.inputs.Primary.bindings = { Device = { keyCode = Enum.KeyCode.Thumbstick1 } }
	TestUtils.install(fixture, definition)
	TestUtils.enable(fixture)
	TestUtils.emit(fixture, "StateChanged", Vector2.new(0.4, 0.7))
	TestUtils.emit(fixture, "StateChanged", Vector2.new(0.4, 0.7))
	TestUtils.emit(fixture, "Pressed", true)
	TestUtils.emit(fixture, "Released", false)
	TestUtils.emit(fixture, "StateChanged", Vector2.zero)
	expect(TestUtils.kinds(fixture)).toEqual({ "StateChanged", "StateChanged" })
	expect((fixture.events[1] :: Types.ValueChange).value).toBe(Vector2.new(0.4, 0.7))
	expect((fixture.events[2] :: Types.ValueChange).value).toBe(Vector2.zero)
	expect(fixture.owner.SetContextEnabled("Gameplay", false)).toBe(true)
	expect(#fixture.events).toBe(2)
end)

it("emits changed Direction3D values and real typed neutral without Bool edges", function()
	local definition: TestUtils.CoreDefinition = TestUtils.definition(Enum.InputActionType.Direction3D)

	definition.inputs.Primary.bindings =
		{ Device = { forward = Enum.KeyCode.W, backward = Enum.KeyCode.S, up = Enum.KeyCode.E, down = Enum.KeyCode.Q } }

	TestUtils.install(fixture, definition)
	TestUtils.enable(fixture)
	TestUtils.emit(fixture, "StateChanged", Vector3.new(1, 0, -1))
	TestUtils.emit(fixture, "StateChanged", Vector3.new(1, 0, -1))
	TestUtils.emit(fixture, "Pressed", true)
	TestUtils.emit(fixture, "Released", false)
	TestUtils.emit(fixture, "StateChanged", Vector3.zero)
	expect(TestUtils.kinds(fixture)).toEqual({ "StateChanged", "StateChanged" })
	expect((fixture.events[1] :: Types.ValueChange).value).toBe(Vector3.new(1, 0, -1))
	expect((fixture.events[2] :: Types.ValueChange).value).toBe(Vector3.zero)
	expect(fixture.owner.SetContextEnabled("Gameplay", false)).toBe(true)
	expect(#fixture.events).toBe(2)
end)

it("treats viewport zero as a position and never creates a held cancellation", function()
	local definition: TestUtils.CoreDefinition = TestUtils.definition(Enum.InputActionType.ViewportPosition)
	definition.inputs.Primary.bindings = { Pointer = { pointerIndex = 0 } }
	TestUtils.install(fixture, definition)
	TestUtils.enable(fixture)
	TestUtils.emit(fixture, "StateChanged", Vector2.new(100, 50))
	TestUtils.emit(fixture, "StateChanged", Vector2.zero)
	TestUtils.emit(fixture, "StateChanged", Vector2.zero)
	expect(fixture.owner.SetContextEnabled("Gameplay", false)).toBe(true)
	expect(TestUtils.kinds(fixture)).toEqual({ "StateChanged", "StateChanged" })
	expect((fixture.events[2] :: Types.ValueChange).value).toBe(Vector2.zero)
end)

it("rejects wrong native payload types and nonfinite values without poisoning later delivery", function()
	local definition: TestUtils.CoreDefinition = TestUtils.definition(Enum.InputActionType.Direction1D)
	definition.inputs.Primary.bindings = { Gamepad = { keyCode = Enum.KeyCode.ButtonR2 } }
	TestUtils.install(fixture, definition)
	TestUtils.enable(fixture)

	for _, value: any in { "bad", true, Vector2.zero, Vector3.zero, 0 / 0, math.huge } do
		TestUtils.emit(fixture, "StateChanged", value)
	end

	expect(#fixture.events).toBe(0)
	TestUtils.emit(fixture, "StateChanged", 0.5)
	expect(#fixture.events).toBe(1)
	expect((fixture.events[1] :: Types.ValueChange).value).toBe(0.5)
end)
