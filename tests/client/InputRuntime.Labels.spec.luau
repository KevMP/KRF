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

it("rejects an unknown semantic input without changing the consumer label", function()
	local label: InputActionLabel = Instance.new("InputActionLabel")
	label.Parent = fixture.container
	expect({ fixture.owner.BindActionLabel("Missing", label) }).toEqual({ false, "UnknownInput" })
	expect(label.InputAction).toBeNil()
	expect(label.Parent).toBe(fixture.container)
end)

it("binds and rebinds one label association without exposing native handles through queries", function()
	TestUtils.install(fixture)

	expect(fixture.owner.SetSource("Other", {
		inputs = {
			Secondary = {
				context = "Gameplay",
				type = Enum.InputActionType.Bool,
				bindings = { Keyboard = { keyCode = Enum.KeyCode.F } },
			},
		},
	})).toBe(true)

	local label: InputActionLabel = Instance.new("InputActionLabel")
	label.Parent = fixture.container
	expect(fixture.owner.BindActionLabel("Primary", label)).toBe(true)
	expect(label.InputAction).toBe(fixture.actions.Primary)
	expect(fixture.owner.BindActionLabel("Secondary", label)).toBe(true)
	expect(label.InputAction).toBe(fixture.actions.Secondary)
	expect(fixture.owner.UnbindActionLabel(label)).toBe(true)
	expect(label.InputAction).toBeNil()
	expect(fixture.owner.UnbindActionLabel(label)).toBe(true)
	expect(label.Parent).toBe(fixture.container)
end)

it("repoints a label when the managed native Action is replaced", function()
	TestUtils.install(fixture)

	local label: InputActionLabel = Instance.new("InputActionLabel")
	label.Parent = fixture.container
	expect(fixture.owner.BindActionLabel("Primary", label)).toBe(true)
	local previous: InputAction = label.InputAction

	local definition: TestUtils.CoreDefinition = TestUtils.definition(Enum.InputActionType.Direction1D)
	definition.inputs.Primary.bindings = { Gamepad = { keyCode = Enum.KeyCode.ButtonR2 } }
	expect(fixture.owner.SetSource("Core", definition)).toBe(true)
	expect(label.InputAction).toBe(fixture.actions.Primary)
	expect(label.InputAction).never.toBe(previous)
	expect(fixture.owner.RemoveSource("Core")).toBe(true)
	expect(label.InputAction).toBeNil()
	expect(label.Parent).toBe(fixture.container)
end)

it("respects external label assignment during unbind and source teardown", function()
	TestUtils.install(fixture)

	local label: InputActionLabel = Instance.new("InputActionLabel")
	label.Parent = fixture.container

	local external: InputAction = Instance.new("InputAction")
	external.Parent = fixture.container
	expect(fixture.owner.BindActionLabel("Primary", label)).toBe(true)
	label.InputAction = external
	expect(fixture.owner.UnbindActionLabel(label)).toBe(true)
	expect(label.InputAction).toBe(external)
	expect(fixture.owner.BindActionLabel("Primary", label)).toBe(true)
	label.InputAction = external
	expect(fixture.owner.RemoveSource("Core")).toBe(true)
	expect(label.InputAction).toBe(external)
	expect(external.Parent).toBe(fixture.container)
end)

it("releases destroyed label references and never destroys consumer UI on owner cleanup", function()
	TestUtils.install(fixture)
	local consumer: Folder = Instance.new("Folder")

	local label: InputActionLabel = Instance.new("InputActionLabel")
	label.Parent = consumer

	local button: TextButton = Instance.new("TextButton")
	button.Parent = consumer

	local definition: TestUtils.CoreDefinition = TestUtils.definition()
	definition.inputs.Primary.bindings.Touch = { uiButton = button }
	expect(fixture.owner.SetSource("Core", definition)).toBe(true)
	expect(fixture.owner.BindActionLabel("Primary", label)).toBe(true)
	label:Destroy()
	local success: boolean, reason: any = pcall(fixture.owner.Destroy)
	local parent: Instance? = button.Parent
	consumer:Destroy()
	expect({ success, reason }).toEqual({ true })
	expect(parent).toBe(consumer)
	expect(fixture.connections).toBe(0)
end)
