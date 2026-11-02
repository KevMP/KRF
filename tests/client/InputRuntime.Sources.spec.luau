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

it("rejects duplicate canonical owners while allowing overlapping physical keys", function()
	TestUtils.install(fixture)
	local before: number = #fixture.writes
	local success: boolean, reason: string? = fixture.owner.SetSource("Other", TestUtils.definition())
	expect({ success, reason }).toEqual({ false, "DuplicateContextOwner" })
	expect(#fixture.writes).toBe(before)

	expect({
		fixture.owner.SetSource("Other", {
			inputs = {
				Primary = {
					context = "Gameplay",
					type = Enum.InputActionType.Bool,
					bindings = { Keyboard = { keyCode = Enum.KeyCode.Q } },
				},
			},
		}),
	}).toEqual({ false, "DuplicateInputOwner" })

	expect(fixture.owner.SetSource("Other", {
		inputs = {
			Secondary = {
				context = "Gameplay",
				type = Enum.InputActionType.Bool,
				bindings = { Keyboard = { keyCode = Enum.KeyCode.Q } },
			},
		},
	})).toBe(true)

	expect(fixture.actions.Secondary.Parent).toBe(fixture.contexts.Gameplay)
end)

it("rejects removing or replacing a referenced context without modifying either source", function()
	TestUtils.install(fixture)

	expect(fixture.owner.SetSource("Other", {
		inputs = {
			Secondary = {
				context = "Gameplay",
				type = Enum.InputActionType.Bool,
				bindings = { Keyboard = { keyCode = Enum.KeyCode.E } },
			},
		},
	})).toBe(true)

	local before: number = #fixture.writes
	expect({ fixture.owner.RemoveSource("Core") }).toEqual({ false, "UnknownContext" })
	expect({ fixture.owner.SetSource("Core", {}) }).toEqual({ false, "UnknownContext" })
	expect(#fixture.writes).toBe(before)
	expect((assert(fixture.owner.GetInput("Secondary"), "Expected installed input")).sourceId).toBe("Other")
	expect((assert(fixture.owner.GetInput("Primary"), "Expected installed input")).sourceId).toBe("Core")
end)

it("restores the next whole binding slot and leaves other device slots unchanged", function()
	TestUtils.install(fixture)
	local gamepad: InputBinding = fixture.bindings["Primary:Gamepad"]

	expect(
		fixture.owner.SetSource(
			"Low",
			{ priority = 10, bindingOverrides = { Primary = { Keyboard = { keyCode = Enum.KeyCode.E } } } }
		)
	).toBe(true)

	expect(
		fixture.owner.SetSource(
			"High",
			{ priority = 20, bindingOverrides = { Primary = { Keyboard = { keyCode = Enum.KeyCode.R } } } }
		)
	).toBe(true)

	expect((assert(fixture.owner.GetEffectiveBindings("Primary"), "Expected effective bindings")).Keyboard.sourceId).toBe(
		"High"
	)

	expect(
		(assert(fixture.owner.GetEffectiveBindings("Primary"), "Expected effective bindings")).Keyboard.definition.keyCode
	).toBe(Enum.KeyCode.R)

	expect(fixture.bindings["Primary:Gamepad"]).toBe(gamepad)
	expect(fixture.owner.RemoveSource("High")).toBe(true)

	expect((assert(fixture.owner.GetEffectiveBindings("Primary"), "Expected effective bindings")).Keyboard.sourceId).toBe(
		"Low"
	)

	expect(fixture.owner.RemoveSource("Low")).toBe(true)

	expect((assert(fixture.owner.GetEffectiveBindings("Primary"), "Expected effective bindings")).Keyboard.sourceId).toBe(
		"Core"
	)

	expect(fixture.bindings["Primary:Gamepad"]).toBe(gamepad)
end)

it("does not merge modifier fields from the overridden base slot", function()
	local definition: TestUtils.CoreDefinition = TestUtils.definition()
	definition.inputs.Primary.bindings.Keyboard.primaryModifier = Enum.KeyCode.LeftShift
	TestUtils.install(fixture, definition)

	expect(
		fixture.owner.SetSource(
			"Rebind",
			{ bindingOverrides = { Primary = { Keyboard = { keyCode = Enum.KeyCode.E } } } }
		)
	).toBe(true)

	expect(
		(assert(fixture.owner.GetEffectiveBindings("Primary"), "Expected effective bindings")).Keyboard.definition.primaryModifier
	).toBeNil()

	local defaultBinding: InputBinding = Instance.new("InputBinding")
	defaultBinding.Parent = fixture.container
	expect(fixture.bindings["Primary:Keyboard"].PrimaryModifier).toBe(defaultBinding.PrimaryModifier)
end)

it("rejects equal winning overlay priorities and preserves the installed winner", function()
	TestUtils.install(fixture)

	expect(
		fixture.owner.SetSource(
			"First",
			{ priority = 20, bindingOverrides = { Primary = { Keyboard = { keyCode = Enum.KeyCode.E } } } }
		)
	).toBe(true)

	local before: number = #fixture.writes

	expect({
		fixture.owner.SetSource(
			"Second",
			{ priority = 20, bindingOverrides = { Primary = { Keyboard = { keyCode = Enum.KeyCode.R } } } }
		),
	}).toEqual({ false, "BindingOverrideConflict" })

	expect(#fixture.writes).toBe(before)

	expect((assert(fixture.owner.GetEffectiveBindings("Primary"), "Expected effective bindings")).Keyboard.sourceId).toBe(
		"First"
	)
end)

it("permits shadowed ties but rejects removal exposing a tied highest priority", function()
	TestUtils.install(fixture)

	expect(
		fixture.owner.SetSource(
			"High",
			{ priority = 30, bindingOverrides = { Primary = { Keyboard = { keyCode = Enum.KeyCode.T } } } }
		)
	).toBe(true)

	for _, sourceId: string in { "First", "Second" } do
		expect(
			fixture.owner.SetSource(
				sourceId,
				{ priority = 20, bindingOverrides = { Primary = { Keyboard = { keyCode = Enum.KeyCode.E } } } }
			)
		).toBe(true)
	end

	local before: number = #fixture.writes
	expect({ fixture.owner.RemoveSource("High") }).toEqual({ false, "BindingOverrideConflict" })
	expect(#fixture.writes).toBe(before)

	expect((assert(fixture.owner.GetEffectiveBindings("Primary"), "Expected effective bindings")).Keyboard.sourceId).toBe(
		"High"
	)
end)

it("rejects an unknown overlay input before touching native bindings", function()
	TestUtils.install(fixture)
	local before: number = #fixture.writes

	expect({
		fixture.owner.SetSource(
			"Overlay",
			{ bindingOverrides = { Absent = { Keyboard = { keyCode = Enum.KeyCode.E } } } }
		),
	}).toEqual({ false, "UnknownInput" })

	expect(#fixture.writes).toBe(before)
end)

it("rejects an unknown overlay slot before touching native bindings", function()
	TestUtils.install(fixture)
	local before: number = #fixture.writes

	expect({
		fixture.owner.SetSource(
			"Overlay",
			{ bindingOverrides = { Primary = { Missing = { keyCode = Enum.KeyCode.E } } } }
		),
	}).toEqual({ false, "UnknownBindingSlot" })

	expect(#fixture.writes).toBe(before)
end)

it("rejects removal of an input with a surviving binding overlay", function()
	TestUtils.install(fixture)

	expect(
		fixture.owner.SetSource(
			"Rebind",
			{ bindingOverrides = { Primary = { Keyboard = { keyCode = Enum.KeyCode.E } } } }
		)
	).toBe(true)

	local before: number = #fixture.writes
	expect({ fixture.owner.RemoveSource("Core") }).toEqual({ false, "UnknownInput" })
	expect(#fixture.writes).toBe(before)
	expect(fixture.owner.RemoveSource("Rebind")).toBe(true)
	expect(fixture.owner.RemoveSource("Core")).toBe(true)
	expect(#fixture.container:GetDescendants()).toBe(0)
end)
