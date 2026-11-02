--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local TestUtils = require(script.Parent.Utils.InputTestUtils)

local fixture: TestUtils.Fixture

beforeEach(function()
	fixture = TestUtils.new()
end)

afterEach(function()
	TestUtils.destroy(fixture)
end)

it("rejects unknown binding properties atomically", function()
	local definition: TestUtils.CoreDefinition = TestUtils.definition()
	definition.inputs.Primary.bindings.Keyboard = { keyCode = Enum.KeyCode.Q, unknown = true } :: any
	local success: boolean, reason: string? = fixture.owner.SetSource("Core", definition)
	expect({ success, reason }).toEqual({ false, "InvalidBinding" })
	expect(#fixture.writes).toBe(0)
end)

it("rejects a string instead of KeyCode atomically", function()
	local definition: TestUtils.CoreDefinition = TestUtils.definition()
	definition.inputs.Primary.bindings.Keyboard = { keyCode = "Q" } :: any
	local success: boolean, reason: string? = fixture.owner.SetSource("Core", definition)
	expect({ success, reason }).toEqual({ false, "InvalidBinding" })
	expect(#fixture.writes).toBe(0)
end)

it("rejects a foreign enum atomically", function()
	local definition: TestUtils.CoreDefinition = TestUtils.definition()
	definition.inputs.Primary.bindings.Keyboard = { keyCode = Enum.InputActionType.Bool } :: any
	local success: boolean, reason: string? = fixture.owner.SetSource("Core", definition)
	expect({ success, reason }).toEqual({ false, "InvalidBinding" })
	expect(#fixture.writes).toBe(0)
end)

it("rejects an empty slot atomically", function()
	local definition: TestUtils.CoreDefinition = TestUtils.definition()
	definition.inputs.Primary.bindings.Keyboard = {} :: any
	local success: boolean, reason: string? = fixture.owner.SetSource("Core", definition)
	expect({ success, reason }).toEqual({ false, "InvalidBinding" })
	expect(#fixture.writes).toBe(0)
end)

it("rejects nonfinite scale atomically", function()
	local definition: TestUtils.CoreDefinition = TestUtils.definition()
	definition.inputs.Primary.bindings.Keyboard = { keyCode = Enum.KeyCode.Q, scale = math.huge } :: any
	local success: boolean, reason: string? = fixture.owner.SetSource("Core", definition)
	expect({ success, reason }).toEqual({ false, "InvalidBinding" })
	expect(#fixture.writes).toBe(0)
end)

it("rejects nonfinite threshold atomically", function()
	local definition: TestUtils.CoreDefinition = TestUtils.definition()
	definition.inputs.Primary.bindings.Keyboard = { keyCode = Enum.KeyCode.ButtonR2, pressedThreshold = 0 / 0 } :: any
	local success: boolean, reason: string? = fixture.owner.SetSource("Core", definition)
	expect({ success, reason }).toEqual({ false, "InvalidBinding" })
	expect(#fixture.writes).toBe(0)
end)

it("rejects inverted threshold hysteresis atomically", function()
	local definition: TestUtils.CoreDefinition = TestUtils.definition()

	definition.inputs.Primary.bindings.Keyboard =
		{ keyCode = Enum.KeyCode.ButtonR2, pressedThreshold = 0.2, releasedThreshold = 0.8 } :: any

	local success: boolean, reason: string? = fixture.owner.SetSource("Core", definition)
	expect({ success, reason }).toEqual({ false, "InvalidBinding" })
	expect(#fixture.writes).toBe(0)
end)

it("rejects negative response curve atomically", function()
	local definition: TestUtils.CoreDefinition = TestUtils.definition()
	definition.inputs.Primary.bindings.Keyboard = { keyCode = Enum.KeyCode.ButtonR2, responseCurve = -1 } :: any
	local success: boolean, reason: string? = fixture.owner.SetSource("Core", definition)
	expect({ success, reason }).toEqual({ false, "InvalidBinding" })
	expect(#fixture.writes).toBe(0)
end)

it("rejects a nonbutton UI reference atomically", function()
	local definition: TestUtils.CoreDefinition = TestUtils.definition()
	definition.inputs.Primary.bindings.Keyboard = { uiButton = fixture.container } :: any
	local success: boolean, reason: string? = fixture.owner.SetSource("Core", definition)
	expect({ success, reason }).toEqual({ false, "InvalidBinding" })
	expect(#fixture.writes).toBe(0)
end)

it("rejects a direction vector on Bool atomically", function()
	local definition: TestUtils.CoreDefinition = TestUtils.definition()
	definition.inputs.Primary.bindings.Keyboard = { keyCode = Enum.KeyCode.Q, vector3Scale = Vector3.one } :: any
	local success: boolean, reason: string? = fixture.owner.SetSource("Core", definition)
	expect({ success, reason }).toEqual({ false, "InvalidBinding" })
	expect(#fixture.writes).toBe(0)
end)

it("rejects public Scriptable injection atomically", function()
	local definition: TestUtils.CoreDefinition = TestUtils.definition()
	definition.inputs.Primary.bindings.Keyboard = { type = Enum.InputBindingType.Scriptable } :: any
	local success: boolean, reason: string? = fixture.owner.SetSource("Core", definition)
	expect({ success, reason }).toEqual({ false, "InvalidBinding" })
	expect(#fixture.writes).toBe(0)
end)

it("rejects noninteger pointer index atomically", function()
	local definition: TestUtils.CoreDefinition = TestUtils.definition()
	definition.inputs.Primary.bindings.Keyboard = { pointerIndex = 0.5 } :: any
	local success: boolean, reason: string? = fixture.owner.SetSource("Core", definition)
	expect({ success, reason }).toEqual({ false, "InvalidBinding" })
	expect(#fixture.writes).toBe(0)
end)

it("rejects a string display image atomically", function()
	local definition: TestUtils.CoreDefinition = TestUtils.definition()
	definition.inputs.Primary.bindings.Keyboard = { keyCode = Enum.KeyCode.Q, displayImage = "rbxassetid://1" } :: any
	local success: boolean, reason: string? = fixture.owner.SetSource("Core", definition)
	expect({ success, reason }).toEqual({ false, "InvalidBinding" })
	expect(#fixture.writes).toBe(0)
end)

it("accepts native modifiers thresholds UI references and display metadata without owning the UI", function()
	local button: TextButton = Instance.new("TextButton")
	button.Parent = fixture.container

	local modifier: TextButton = Instance.new("TextButton")
	modifier.Parent = fixture.container

	local definition: TestUtils.CoreDefinition = TestUtils.definition()

	definition.inputs.Primary.bindings.Keyboard = {
		keyCode = Enum.KeyCode.Q,
		primaryModifier = Enum.KeyCode.LeftShift,
		secondaryModifier = Enum.KeyCode.LeftControl,
		displayName = "Charge",
		displayImage = Content.none,
	}

	definition.inputs.Primary.bindings.Gamepad =
		{ keyCode = Enum.KeyCode.ButtonR2, pressedThreshold = 0.8, releasedThreshold = 0.2 }

	definition.inputs.Primary.bindings.Touch = { uiButton = button, uiModifier = modifier }
	TestUtils.install(fixture, definition)
	expect(fixture.bindings["Primary:Keyboard"].PrimaryModifier).toBe(Enum.KeyCode.LeftShift)
	expect(fixture.bindings["Primary:Keyboard"].SecondaryModifier).toBe(Enum.KeyCode.LeftControl)
	expect(fixture.bindings["Primary:Keyboard"].DisplayName).toBe("Charge")
	expect(fixture.bindings["Primary:Gamepad"].PressedThreshold).toBeCloseTo(0.8, 6)
	expect(fixture.bindings["Primary:Touch"].UIButton).toBe(button)
	expect(fixture.owner.RemoveSource("Core")).toBe(true)
	expect(button.Parent).toBe(fixture.container)
	expect(modifier.Parent).toBe(fixture.container)
end)

it("installs a typed native Direction1D binding", function()
	local definition: TestUtils.CoreDefinition = TestUtils.definition(Enum.InputActionType.Direction1D)

	definition.inputs.Primary.bindings = { Device = { up = Enum.KeyCode.W, down = Enum.KeyCode.S, scale = 2 } }

	TestUtils.install(fixture, definition)
	expect(fixture.actions.Primary.Type).toBe(Enum.InputActionType.Direction1D)
	expect(fixture.bindings["Primary:Device"].Type).toBe(Enum.InputBindingType.Automatic)

	expect((assert(fixture.owner.GetInput("Primary"), "Expected installed input")).inputType).toBe(
		Enum.InputActionType.Direction1D
	)
end)

it("installs a typed native Direction2D binding", function()
	local definition: TestUtils.CoreDefinition = TestUtils.definition(Enum.InputActionType.Direction2D)

	definition.inputs.Primary.bindings = {
		Device = {
			up = Enum.KeyCode.W,
			down = Enum.KeyCode.S,
			left = Enum.KeyCode.A,
			right = Enum.KeyCode.D,
			vector2Scale = Vector2.one,
			clampMagnitudeToOne = true,
		},
	}

	TestUtils.install(fixture, definition)
	expect(fixture.actions.Primary.Type).toBe(Enum.InputActionType.Direction2D)
	expect(fixture.bindings["Primary:Device"].Type).toBe(Enum.InputBindingType.Automatic)

	expect((assert(fixture.owner.GetInput("Primary"), "Expected installed input")).inputType).toBe(
		Enum.InputActionType.Direction2D
	)
end)

it("installs a typed native Direction3D binding", function()
	local definition: TestUtils.CoreDefinition = TestUtils.definition(Enum.InputActionType.Direction3D)

	definition.inputs.Primary.bindings = {
		Device = {
			forward = Enum.KeyCode.W,
			backward = Enum.KeyCode.S,
			left = Enum.KeyCode.A,
			right = Enum.KeyCode.D,
			up = Enum.KeyCode.E,
			down = Enum.KeyCode.Q,
			vector3Scale = Vector3.one,
			clampMagnitudeToOne = true,
		},
	}

	TestUtils.install(fixture, definition)
	expect(fixture.actions.Primary.Type).toBe(Enum.InputActionType.Direction3D)
	expect(fixture.bindings["Primary:Device"].Type).toBe(Enum.InputBindingType.Automatic)

	expect((assert(fixture.owner.GetInput("Primary"), "Expected installed input")).inputType).toBe(
		Enum.InputActionType.Direction3D
	)
end)

it("installs a typed native ViewportPosition binding", function()
	local definition: TestUtils.CoreDefinition = TestUtils.definition(Enum.InputActionType.ViewportPosition)
	definition.inputs.Primary.bindings = { Device = { keyCode = Enum.KeyCode.MousePosition, pointerIndex = 0 } }
	TestUtils.install(fixture, definition)
	expect(fixture.actions.Primary.Type).toBe(Enum.InputActionType.ViewportPosition)
	expect(fixture.bindings["Primary:Device"].Type).toBe(Enum.InputBindingType.Automatic)

	expect((assert(fixture.owner.GetInput("Primary"), "Expected installed input")).inputType).toBe(
		Enum.InputActionType.ViewportPosition
	)
end)
