--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local Types = require(KRF.client.Input.types)
local Constants = require(KRF.client.Input.utils.InputConstants)
local Validator = require(KRF.client.Input.InputValidator)
local TestUtils = require(script.Parent.Utils.InputTestUtils)

local fixture: TestUtils.Fixture

beforeEach(function()
	fixture = TestUtils.new()
end)

afterEach(function()
	TestUtils.destroy(fixture)
end)

it("rejects finite numbers that cannot be represented by native IAS properties", function()
	local oversizedScale: TestUtils.CoreDefinition = TestUtils.definition(Enum.InputActionType.Direction1D)
	oversizedScale.inputs.Primary.bindings = { Device = { keyCode = Enum.KeyCode.ButtonR2, scale = 1e40 } }

	local oversizedPointer: TestUtils.CoreDefinition = TestUtils.definition(Enum.InputActionType.ViewportPosition)

	oversizedPointer.inputs.Primary.bindings =
		{ Pointer = { keyCode = Enum.KeyCode.MousePosition, pointerIndex = 2147483648 } }

	local cases: { { definition: any, reason: string } } = {
		{
			definition = { contexts = { Gameplay = { priority = 2147483648, sink = false } } },
			reason = "InvalidContext",
		},
		{
			definition = { contexts = { Gameplay = { priority = -2147483649, sink = false } } },
			reason = "InvalidContext",
		},
		{ definition = oversizedScale, reason = "InvalidBinding" },
		{ definition = oversizedPointer, reason = "InvalidBinding" },
	}

	for _, case in cases do
		expect({ fixture.owner.SetSource("Bad", case.definition) }).toEqual({ false, case.reason })
	end

	expect(#fixture.writes).toBe(0)
end)

it("rejects a non-table context map without native writes", function()
	local success: boolean, reason: string? = fixture.owner.SetSource("Bad", { contexts = false } :: any)
	expect({ success, reason }).toEqual({ false, "InvalidDefinition" })
	expect(#fixture.writes).toBe(0)
end)

it("rejects a non-table input map without native writes", function()
	local success: boolean, reason: string? = fixture.owner.SetSource("Bad", { inputs = 1 } :: any)
	expect({ success, reason }).toEqual({ false, "InvalidDefinition" })
	expect(#fixture.writes).toBe(0)
end)

it("rejects a non-table overlay map without native writes", function()
	local success: boolean, reason: string? = fixture.owner.SetSource("Bad", { bindingOverrides = false } :: any)
	expect({ success, reason }).toEqual({ false, "InvalidDefinition" })
	expect(#fixture.writes).toBe(0)
end)

it("rejects unknown context properties without native writes", function()
	local success: boolean, reason: string? = fixture.owner.SetSource(
		"Bad",
		{ contexts = { Gameplay = { priority = 1, sink = false, enabled = true } } } :: any
	)

	expect({ success, reason }).toEqual({ false, "InvalidContext" })
	expect(#fixture.writes).toBe(0)
end)

it("rejects fractional context priority without native writes", function()
	local success: boolean, reason: string? =
		fixture.owner.SetSource("Bad", { contexts = { Gameplay = { priority = 1.5, sink = false } } } :: any)

	expect({ success, reason }).toEqual({ false, "InvalidContext" })
	expect(#fixture.writes).toBe(0)
end)

it("rejects a non-table binding map without native writes", function()
	local success: boolean, reason: string? = fixture.owner.SetSource(
		"Bad",
		{
			contexts = { Gameplay = { priority = 0, sink = false } },
			inputs = { Primary = { context = "Gameplay", type = Enum.InputActionType.Bool, bindings = false } },
		} :: any
	)

	expect({ success, reason }).toEqual({ false, "InvalidInput" })
	expect(#fixture.writes).toBe(0)
end)

it("rejects an invalid display name without native writes", function()
	local success: boolean, reason: string? = fixture.owner.SetSource(
		"Bad",
		{
			contexts = { Gameplay = { priority = 0, sink = false } },
			inputs = {
				Primary = { context = "Gameplay", type = Enum.InputActionType.Bool, displayName = false, bindings = {} },
			},
		} :: any
	)

	expect({ success, reason }).toEqual({ false, "InvalidInput" })
	expect(#fixture.writes).toBe(0)
end)

it("rejects an invalid overlay target ID without native writes", function()
	local success: boolean, reason: string? = fixture.owner.SetSource(
		"Bad",
		{ bindingOverrides = { [""] = { Keyboard = { keyCode = Enum.KeyCode.Q } } } } :: any
	)

	expect({ success, reason }).toEqual({ false, "InvalidBinding" })
	expect(#fixture.writes).toBe(0)
end)

it("rejects a non-table overlay slot map without native writes", function()
	local success: boolean, reason: string? =
		fixture.owner.SetSource("Bad", { bindingOverrides = { Primary = false } } :: any)

	expect({ success, reason }).toEqual({ false, "InvalidBinding" })
	expect(#fixture.writes).toBe(0)
end)

it("rejects an empty overlay slot ID without native writes", function()
	local success: boolean, reason: string? = fixture.owner.SetSource(
		"Bad",
		{ bindingOverrides = { Primary = { [""] = { keyCode = Enum.KeyCode.Q } } } } :: any
	)

	expect({ success, reason }).toEqual({ false, "InvalidBinding" })
	expect(#fixture.writes).toBe(0)
end)

it("rejects a malformed overlay config without native writes", function()
	local success: boolean, reason: string? =
		fixture.owner.SetSource("Bad", { bindingOverrides = { Primary = { Keyboard = { keyCode = "Q" } } } } :: any)

	expect({ success, reason }).toEqual({ false, "InvalidBinding" })
	expect(#fixture.writes).toBe(0)
end)

it("rejects a nonfinite Vector2 scale", function()
	local definition: TestUtils.CoreDefinition = TestUtils.definition(Enum.InputActionType.Direction2D)

	definition.inputs.Primary.bindings =
		{ Device = { keyCode = Enum.KeyCode.Thumbstick1, vector2Scale = Vector2.new(0 / 0, 1) } }

	expect({ fixture.owner.SetSource("Core", definition) }).toEqual({ false, "InvalidBinding" })
	expect(#fixture.writes).toBe(0)
end)

it("rejects a nonfinite Vector3 scale", function()
	local definition: TestUtils.CoreDefinition = TestUtils.definition(Enum.InputActionType.Direction3D)

	definition.inputs.Primary.bindings =
		{ Device = { up = Enum.KeyCode.W, vector3Scale = Vector3.new(1, math.huge, 1) } }

	expect({ fixture.owner.SetSource("Core", definition) }).toEqual({ false, "InvalidBinding" })
	expect(#fixture.writes).toBe(0)
end)

it("rejects a pressed threshold below zero", function()
	local definition: TestUtils.CoreDefinition = TestUtils.definition(Enum.InputActionType.Bool)
	definition.inputs.Primary.bindings = { Device = { keyCode = Enum.KeyCode.ButtonR2, pressedThreshold = -1 } }
	expect({ fixture.owner.SetSource("Core", definition) }).toEqual({ false, "InvalidBinding" })
	expect(#fixture.writes).toBe(0)
end)

it("rejects a release threshold above one", function()
	local definition: TestUtils.CoreDefinition = TestUtils.definition(Enum.InputActionType.Bool)
	definition.inputs.Primary.bindings = { Device = { keyCode = Enum.KeyCode.ButtonR2, releasedThreshold = 2 } }
	expect({ fixture.owner.SetSource("Core", definition) }).toEqual({ false, "InvalidBinding" })
	expect(#fixture.writes).toBe(0)
end)

it("rejects 3D composites on a 1D action", function()
	local definition: TestUtils.CoreDefinition = TestUtils.definition(Enum.InputActionType.Direction1D)
	definition.inputs.Primary.bindings = { Device = { forward = Enum.KeyCode.W } }
	expect({ fixture.owner.SetSource("Core", definition) }).toEqual({ false, "InvalidBinding" })
	expect(#fixture.writes).toBe(0)
end)

it("rejects horizontal composites on a 1D action", function()
	local definition: TestUtils.CoreDefinition = TestUtils.definition(Enum.InputActionType.Direction1D)
	definition.inputs.Primary.bindings = { Device = { left = Enum.KeyCode.A } }
	expect({ fixture.owner.SetSource("Core", definition) }).toEqual({ false, "InvalidBinding" })
	expect(#fixture.writes).toBe(0)
end)

it("rejects directional scaling on Bool", function()
	local definition: TestUtils.CoreDefinition = TestUtils.definition(Enum.InputActionType.Bool)
	definition.inputs.Primary.bindings = { Device = { keyCode = Enum.KeyCode.Q, scale = 2 } }
	expect({ fixture.owner.SetSource("Core", definition) }).toEqual({ false, "InvalidBinding" })
	expect(#fixture.writes).toBe(0)
end)

it("rejects Vector2 scaling on 3D", function()
	local definition: TestUtils.CoreDefinition = TestUtils.definition(Enum.InputActionType.Direction3D)
	definition.inputs.Primary.bindings = { Device = { up = Enum.KeyCode.W, vector2Scale = Vector2.one } }
	expect({ fixture.owner.SetSource("Core", definition) }).toEqual({ false, "InvalidBinding" })
	expect(#fixture.writes).toBe(0)
end)

it("rejects Bool thresholds on a directional action", function()
	local definition: TestUtils.CoreDefinition = TestUtils.definition(Enum.InputActionType.Direction1D)
	definition.inputs.Primary.bindings = { Device = { keyCode = Enum.KeyCode.ButtonR2, pressedThreshold = 0.8 } }
	expect({ fixture.owner.SetSource("Core", definition) }).toEqual({ false, "InvalidBinding" })
	expect(#fixture.writes).toBe(0)
end)

it("rejects a pointer index on Bool", function()
	local definition: TestUtils.CoreDefinition = TestUtils.definition(Enum.InputActionType.Bool)
	definition.inputs.Primary.bindings = { Device = { keyCode = Enum.KeyCode.Q, pointerIndex = 0 } }
	expect({ fixture.owner.SetSource("Core", definition) }).toEqual({ false, "InvalidBinding" })
	expect(#fixture.writes).toBe(0)
end)

it("rejects a response curve without a thumbstick", function()
	local definition: TestUtils.CoreDefinition = TestUtils.definition(Enum.InputActionType.Direction2D)
	definition.inputs.Primary.bindings = { Device = { up = Enum.KeyCode.W, responseCurve = 2 } }
	expect({ fixture.owner.SetSource("Core", definition) }).toEqual({ false, "InvalidBinding" })
	expect(#fixture.writes).toBe(0)
end)

it("rejects a viewport binding without a positional key", function()
	local definition: TestUtils.CoreDefinition = TestUtils.definition(Enum.InputActionType.ViewportPosition)
	definition.inputs.Primary.bindings = { Device = { pointerIndex = 0 } }
	expect({ fixture.owner.SetSource("Core", definition) }).toEqual({ false, "InvalidBinding" })
	expect(#fixture.writes).toBe(0)
end)

it("rejects modifiers without a physical input", function()
	local definition: TestUtils.CoreDefinition = TestUtils.definition(Enum.InputActionType.Bool)
	definition.inputs.Primary.bindings = { Device = { primaryModifier = Enum.KeyCode.LeftShift } }
	expect({ fixture.owner.SetSource("Core", definition) }).toEqual({ false, "InvalidBinding" })
	expect(#fixture.writes).toBe(0)
end)

it("rejects a scalar key on a 2D action", function()
	local definition: TestUtils.CoreDefinition = TestUtils.definition(Enum.InputActionType.Direction2D)
	definition.inputs.Primary.bindings = { Device = { keyCode = Enum.KeyCode.Q } }
	expect({ fixture.owner.SetSource("Core", definition) }).toEqual({ false, "InvalidBinding" })
	expect(#fixture.writes).toBe(0)
end)

it("rejects a direct key on a 3D action", function()
	local definition: TestUtils.CoreDefinition = TestUtils.definition(Enum.InputActionType.Direction3D)
	definition.inputs.Primary.bindings = { Device = { keyCode = Enum.KeyCode.Q } }
	expect({ fixture.owner.SetSource("Core", definition) }).toEqual({ false, "InvalidBinding" })
	expect(#fixture.writes).toBe(0)
end)

it("rejects a vector key on Bool", function()
	local definition: TestUtils.CoreDefinition = TestUtils.definition(Enum.InputActionType.Bool)
	definition.inputs.Primary.bindings = { Device = { keyCode = Enum.KeyCode.Thumbstick1 } }
	expect({ fixture.owner.SetSource("Core", definition) }).toEqual({ false, "InvalidBinding" })
	expect(#fixture.writes).toBe(0)
end)

it("validates overlay configurations against the canonical action type", function()
	TestUtils.install(fixture)
	local before: number = #fixture.writes

	expect({
		fixture.owner.SetSource("Bad", { bindingOverrides = { Primary = { Keyboard = { up = Enum.KeyCode.W } } } }),
	}).toEqual({ false, "InvalidBinding" })

	expect(#fixture.writes).toBe(before)
end)

it("bounds empty overlay target maps before graph composition", function()
	local targets: { [string]: { [string]: Types.BindingDefinition } } = {}

	for index: number = 1, Constants.MAX_INPUTS + 1 do
		targets["Input" .. index] = {}
	end

	expect({ fixture.owner.SetSource("Bad", { bindingOverrides = targets }) }).toEqual({
		false,
		"InputOverrideLimitExceeded",
	})

	expect(#fixture.writes).toBe(0)
end)

it("enforces composed context and input budgets across individually valid sources", function()
	local previous: Types.InputGraphSnapshot =
		{ generation = 0, sources = {}, contexts = {}, inputs = {}, bindings = {} }

	local contexts: { [string]: Types.ContextDefinition } = {}

	for index: number = 1, Constants.MAX_CONTEXTS do
		contexts["Context" .. index] = { priority = 0, sink = false }
	end

	local first: Types.InputSourceDefinition =
		assert(Validator.Normalize("First", { contexts = contexts }), "Expected valid contexts")

	local second: Types.InputSourceDefinition = assert(
		Validator.Normalize("Second", { contexts = { Extra = { priority = 0, sink = false } } }),
		"Expected valid extra context"
	)

	local graph: Types.InputGraphSnapshot?, reason: string? =
		Validator.Compose({ First = first, Second = second }, previous)

	expect(graph).toBeNil()
	expect(reason).toBe("InputContextLimitExceeded")
	local inputs: { [string]: Types.InputDefinition } = {}

	for index: number = 1, Constants.MAX_INPUTS do
		inputs["Input" .. index] = { context = "Gameplay", type = Enum.InputActionType.Bool, bindings = {} }
	end

	first = assert(
		Validator.Normalize("First", { contexts = { Gameplay = { priority = 0, sink = false } }, inputs = inputs }),
		"Expected valid inputs"
	)

	second = assert(
		Validator.Normalize(
			"Second",
			{ inputs = { Extra = { context = "Gameplay", type = Enum.InputActionType.Bool, bindings = {} } } }
		),
		"Expected valid extra input"
	)

	graph, reason = Validator.Compose({ First = first, Second = second }, previous)
	expect(graph).toBeNil()
	expect(reason).toBe("InputLimitExceeded")
end)

it("enforces composed binding and per-source overlay budgets before allocation", function()
	local previous: Types.InputGraphSnapshot =
		{ generation = 0, sources = {}, contexts = {}, inputs = {}, bindings = {} }

	local slots: { [string]: Types.BindingDefinition } = {}

	for index: number = 1, Constants.MAX_BINDINGS do
		slots["Slot" .. index] = { keyCode = Enum.KeyCode.Q }
	end

	local first: Types.InputSourceDefinition = assert(
		Validator.Normalize("First", {
			contexts = { Gameplay = { priority = 0, sink = false } },
			inputs = { Primary = { context = "Gameplay", type = Enum.InputActionType.Bool, bindings = slots } },
		}),
		"Expected valid bindings"
	)

	local second: Types.InputSourceDefinition = assert(
		Validator.Normalize("Second", {
			inputs = {
				Extra = {
					context = "Gameplay",
					type = Enum.InputActionType.Bool,
					bindings = { Keyboard = { keyCode = Enum.KeyCode.E } },
				},
			},
		}),
		"Expected valid extra input"
	)

	local graph: Types.InputGraphSnapshot?, reason: string? =
		Validator.Compose({ First = first, Second = second }, previous)

	expect(graph).toBeNil()
	expect(reason).toBe("InputBindingLimitExceeded")
	slots.Extra = { keyCode = Enum.KeyCode.E }

	expect({ fixture.owner.SetSource("Bad", { bindingOverrides = { Primary = slots } }) }).toEqual({
		false,
		"InputOverrideLimitExceeded",
	})

	expect(#fixture.writes).toBe(0)
end)
