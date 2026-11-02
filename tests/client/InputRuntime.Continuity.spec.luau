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

it("reapplying equivalent nested data preserves native objects subscriptions and held epoch", function()
	TestUtils.install(fixture)
	TestUtils.enable(fixture)
	local occurrences: { Types.PrimitiveOccurrence } = {}

	fixture.owner.ObservePrimitive("Routing", function(occurrence: Types.PrimitiveOccurrence)
		table.insert(occurrences, occurrence)
	end)

	TestUtils.emit(fixture, "Pressed", true)
	local original: Types.PrimitiveOccurrence = occurrences[1]
	local action: InputAction = fixture.actions.Primary
	local binding: InputBinding = fixture.bindings["Primary:Keyboard"]
	local before: number = #fixture.writes
	expect(fixture.owner.SetSource("Core", TestUtils.definition())).toBe(true)
	expect(#fixture.writes).toBe(before)
	expect(fixture.actions.Primary).toBe(action)
	expect(fixture.bindings["Primary:Keyboard"]).toBe(binding)
	expect(fixture.connections).toBe(1)

	expect(
		fixture.owner.IsPressEpochActive(
			"Primary",
			assert(original.pressEpochId, "Expected Bool press epoch"),
			original.generation
		)
	).toBe(true)

	expect(TestUtils.kinds(fixture)).toEqual({ "Pressed" })
end)

it("changing a shadowed overlay makes no native writes or held cancellation", function()
	TestUtils.install(fixture)

	expect(
		fixture.owner.SetSource(
			"High",
			{ priority = 20, bindingOverrides = { Primary = { Keyboard = { keyCode = Enum.KeyCode.E } } } }
		)
	).toBe(true)

	TestUtils.enable(fixture)
	TestUtils.emit(fixture, "Pressed", true)
	local before: number = #fixture.writes

	expect(
		fixture.owner.SetSource(
			"Low",
			{ priority = 10, bindingOverrides = { Primary = { Keyboard = { keyCode = Enum.KeyCode.R } } } }
		)
	).toBe(true)

	expect(#fixture.writes).toBe(before)
	expect(TestUtils.kinds(fixture)).toEqual({ "Pressed" })
end)

it("changing one effective binding preserves other input actions and device binding identities", function()
	local definition: TestUtils.CoreDefinition = TestUtils.definition()

	definition.inputs.Secondary = {
		context = "Gameplay",
		type = Enum.InputActionType.Bool,
		bindings = { Keyboard = { keyCode = Enum.KeyCode.F } },
	}

	TestUtils.install(fixture, definition)
	local secondary: InputAction = fixture.actions.Secondary
	local gamepad: InputBinding = fixture.bindings["Primary:Gamepad"]

	expect(
		fixture.owner.SetSource(
			"Rebind",
			{ bindingOverrides = { Primary = { Keyboard = { keyCode = Enum.KeyCode.E } } } }
		)
	).toBe(true)

	expect(fixture.actions.Secondary).toBe(secondary)
	expect(fixture.bindings["Primary:Gamepad"]).toBe(gamepad)
end)
