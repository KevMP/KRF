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

it("enables multiple contexts using native priority and sinking without a single-context stack", function()
	TestUtils.install(fixture)
	expect(fixture.owner.SetSource("UI", { contexts = { Menu = { priority = 3000, sink = true } } })).toBe(true)
	TestUtils.enable(fixture)
	expect(fixture.owner.SetContextEnabled("Menu", true)).toBe(true)
	expect(fixture.contexts.Gameplay.Enabled).toBe(true)
	expect(fixture.contexts.Menu.Enabled).toBe(true)
	expect(fixture.contexts.Gameplay.Priority).toBe(2000)
	expect(fixture.contexts.Menu.Priority).toBe(3000)
	expect(fixture.contexts.Menu.Sink).toBe(true)
	expect(fixture.owner.SetContextEnabled("Menu", false)).toBe(true)
	expect(fixture.contexts.Gameplay.Enabled).toBe(true)
end)

it("preserves enabled state for a surviving canonical context even when priority and sink change", function()
	TestUtils.install(fixture)
	TestUtils.enable(fixture)

	local definition: TestUtils.CoreDefinition = TestUtils.definition()
	definition.contexts.Gameplay.priority = 2500
	definition.contexts.Gameplay.sink = false
	expect(fixture.owner.SetSource("Core", definition)).toBe(true)
	expect((assert(fixture.owner.GetContext("Gameplay"), "Expected installed context")).enabled).toBe(true)
	expect(fixture.contexts.Gameplay.Enabled).toBe(true)
	expect(fixture.contexts.Gameplay.Priority).toBe(2500)
	expect(fixture.contexts.Gameplay.Sink).toBe(false)
end)

it("forgets enablement when a context is removed and registered again", function()
	TestUtils.install(fixture)
	TestUtils.enable(fixture)
	expect(fixture.owner.RemoveSource("Core")).toBe(true)
	TestUtils.install(fixture)
	expect((assert(fixture.owner.GetContext("Gameplay"), "Expected installed context")).enabled).toBe(false)
	expect(fixture.contexts.Gameplay.Enabled).toBe(false)
end)

it("preserves activation through unrelated and rejected source updates", function()
	TestUtils.install(fixture)
	TestUtils.enable(fixture)
	expect(fixture.owner.SetSource("UI", { contexts = { Menu = { priority = 3000, sink = false } } })).toBe(true)

	expect({
		fixture.owner.SetSource(
			"Core",
			{ inputs = { Primary = { context = "Missing", type = Enum.InputActionType.Bool, bindings = {} } } }
		),
	}).toEqual({ false, "UnknownContext" })

	expect((assert(fixture.owner.GetContext("Gameplay"), "Expected installed context")).enabled).toBe(true)
end)

it("rejects missing contexts and malformed enablement without native writes", function()
	TestUtils.install(fixture)
	local before: number = #fixture.writes
	expect({ fixture.owner.SetContextEnabled("Absent", true) }).toEqual({ false, "UnknownContext" })
	expect({ fixture.owner.SetContextEnabled("Gameplay", 1 :: any) }).toEqual({ false, "InvalidContextEnabled" })
	expect(#fixture.writes).toBe(before)
end)
