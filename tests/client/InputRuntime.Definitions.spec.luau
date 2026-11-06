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

it("installs canonical inputs under disabled contexts without an Actor or Action catalog", function()
	local success: boolean, reason: string? = fixture.owner.SetSource("Core", TestUtils.definition())
	expect({ success, reason }).toEqual({ true })

	expect(fixture.owner.GetContext("Gameplay")).toEqual({
		id = "Gameplay",
		sourceId = "Core",
		priority = 2000,
		sink = true,
		enabled = false,
	})

	expect(fixture.owner.GetInput("Primary")).toEqual({
		id = "Primary",
		sourceId = "Core",
		contextId = "Gameplay",
		inputType = Enum.InputActionType.Bool,
	})

	expect(fixture.contexts.Gameplay.Enabled).toBe(false)
	expect(fixture.actions.Primary.Parent).toBe(fixture.contexts.Gameplay)
	expect(fixture.bindings["Primary:Keyboard"].Type).toBe(Enum.InputBindingType.Automatic)
end)

it("replaces the whole source and withdraws an empty contribution without touching unrelated sources", function()
	TestUtils.install(fixture)
	expect(fixture.owner.SetSource("UI", { contexts = { Menu = { priority = 4000, sink = true } } })).toBe(true)
	local menu: InputContext = fixture.contexts.Menu
	expect(fixture.owner.SetSource("Core", { contexts = { Gameplay = { priority = 2000, sink = true } } })).toBe(true)
	expect(fixture.owner.GetInput("Primary")).toBeNil()
	expect((assert(fixture.owner.GetContext("Gameplay"), "Expected installed context")).enabled).toBe(false)
	expect(fixture.owner.SetSource("Core", {})).toBe(true)
	expect(fixture.owner.GetContext("Gameplay")).toBeNil()
	expect(fixture.contexts.Menu).toBe(menu)
	expect(fixture.owner.RemoveSource("Missing")).toBe(true)
end)

it("owns nested declarations and returns deeply frozen snapshots without native handles", function()
	local definition: TestUtils.CoreDefinition = TestUtils.definition()
	TestUtils.install(fixture, definition)
	definition.contexts.Gameplay.priority = -12
	definition.inputs.Primary.bindings.Keyboard.keyCode = Enum.KeyCode.E
	definition.inputs.Primary.displayName = "Changed"

	local context: Types.ContextSnapshot = assert(fixture.owner.GetContext("Gameplay"), "Expected installed context")
	local input: Types.InputSnapshot = assert(fixture.owner.GetInput("Primary"), "Expected installed input")

	local bindings: { [string]: Types.BindingSnapshot } =
		assert(fixture.owner.GetEffectiveBindings("Primary"), "Expected effective bindings")

	expect(context.priority).toBe(2000)
	expect(input.displayName).toBeNil()
	expect(bindings.Keyboard.definition.keyCode).toBe(Enum.KeyCode.Q)
	expect(table.isfrozen(context)).toBe(true)
	expect(table.isfrozen(input)).toBe(true)
	expect(table.isfrozen(bindings)).toBe(true)
	expect(table.isfrozen(bindings.Keyboard)).toBe(true)
	expect(table.isfrozen(bindings.Keyboard.definition)).toBe(true)
	expect((input :: any).action).toBeNil()

	local mutable: boolean = pcall(function()
		(bindings.Keyboard.definition :: any).keyCode = Enum.KeyCode.E
	end)

	expect(mutable).toBe(false)
end)

it("rejects empty source ID before any native mutation", function()
	local success: boolean, reason: string? = fixture.owner.SetSource("", TestUtils.definition())
	expect({ success, reason }).toEqual({ false, "InvalidSourceId" })
	expect(#fixture.writes).toBe(0)
	expect(fixture.owner.GetInput("Primary")).toBeNil()
end)

it("rejects non-table source before any native mutation", function()
	local success: boolean, reason: string? = fixture.owner.SetSource("Core", false :: any)
	expect({ success, reason }).toEqual({ false, "InvalidDefinition" })
	expect(#fixture.writes).toBe(0)
	expect(fixture.owner.GetInput("Primary")).toBeNil()
end)

it("rejects metatable source before any native mutation", function()
	local success: boolean, reason: string? = fixture.owner.SetSource("Core", setmetatable({}, {}) :: any)
	expect({ success, reason }).toEqual({ false, "InvalidDefinition" })
	expect(#fixture.writes).toBe(0)
	expect(fixture.owner.GetInput("Primary")).toBeNil()
end)

it("rejects malformed gesture declarations before any native mutation", function()
	local success: boolean, reason: string? = fixture.owner.SetSource("Core", { gestures = { Tap = {} } } :: any)
	expect({ success, reason }).toEqual({ false, "InvalidGesture" })
	expect(#fixture.writes).toBe(0)
	expect(fixture.owner.GetInput("Primary")).toBeNil()
end)

it("accepts an empty sequence contribution without native mutation", function()
	local success: boolean, reason: string? = fixture.owner.SetSource("Core", { sequences = {} })
	expect({ success, reason }).toEqual({ true })
	expect(#fixture.writes).toBe(0)
	expect(fixture.owner.GetInput("Primary")).toBeNil()
end)

it("rejects unknown top-level property before any native mutation", function()
	local success: boolean, reason: string? = fixture.owner.SetSource("Core", { typo = true } :: any)
	expect({ success, reason }).toEqual({ false, "InvalidDefinition" })
	expect(#fixture.writes).toBe(0)
	expect(fixture.owner.GetInput("Primary")).toBeNil()
end)

it("rejects empty context ID before any native mutation", function()
	local success: boolean, reason: string? =
		fixture.owner.SetSource("Core", { contexts = { [""] = { priority = 1, sink = false } } })

	expect({ success, reason }).toEqual({ false, "InvalidContext" })
	expect(#fixture.writes).toBe(0)
	expect(fixture.owner.GetInput("Primary")).toBeNil()
end)

it("rejects nonfinite context priority before any native mutation", function()
	local success: boolean, reason: string? =
		fixture.owner.SetSource("Core", { contexts = { Gameplay = { priority = math.huge, sink = false } } })

	expect({ success, reason }).toEqual({ false, "InvalidContext" })
	expect(#fixture.writes).toBe(0)
	expect(fixture.owner.GetInput("Primary")).toBeNil()
end)

it("rejects nonboolean sinking before any native mutation", function()
	local success: boolean, reason: string? =
		fixture.owner.SetSource("Core", { contexts = { Gameplay = { priority = 0, sink = "true" } } } :: any)

	expect({ success, reason }).toEqual({ false, "InvalidContext" })
	expect(#fixture.writes).toBe(0)
	expect(fixture.owner.GetInput("Primary")).toBeNil()
end)

it("rejects nonfinite overlay priority before any native mutation", function()
	local success: boolean, reason: string? = fixture.owner.SetSource("Core", { priority = 0 / 0 })
	expect({ success, reason }).toEqual({ false, "InvalidDefinition" })
	expect(#fixture.writes).toBe(0)
	expect(fixture.owner.GetInput("Primary")).toBeNil()
end)

it("rejects missing context before any native mutation", function()
	local success: boolean, reason: string? = fixture.owner.SetSource(
		"Core",
		{ inputs = { Primary = { context = "Absent", type = Enum.InputActionType.Bool, bindings = {} } } }
	)

	expect({ success, reason }).toEqual({ false, "UnknownContext" })
	expect(#fixture.writes).toBe(0)
	expect(fixture.owner.GetInput("Primary")).toBeNil()
end)

it("rejects wrong action enum before any native mutation", function()
	local success: boolean, reason: string? = fixture.owner.SetSource(
		"Core",
		{
			contexts = { Gameplay = { priority = 0, sink = false } },
			inputs = { Primary = { context = "Gameplay", type = Enum.KeyCode.Q, bindings = {} } },
		} :: any
	)

	expect({ success, reason }).toEqual({ false, "InvalidInput" })
	expect(#fixture.writes).toBe(0)
	expect(fixture.owner.GetInput("Primary")).toBeNil()
end)

it("rejects unknown input field before any native mutation", function()
	local success: boolean, reason: string? = fixture.owner.SetSource(
		"Core",
		{
			contexts = { Gameplay = { priority = 0, sink = false } },
			inputs = {
				Primary = { context = "Gameplay", type = Enum.InputActionType.Bool, bindings = {}, gesture = "Tap" },
			},
		} :: any
	)

	expect({ success, reason }).toEqual({ false, "InvalidInput" })
	expect(#fixture.writes).toBe(0)
	expect(fixture.owner.GetInput("Primary")).toBeNil()
end)

it("rejects empty input ID before any native mutation", function()
	local success: boolean, reason: string? = fixture.owner.SetSource("Core", {
		contexts = { Gameplay = { priority = 0, sink = false } },
		inputs = { [""] = { context = "Gameplay", type = Enum.InputActionType.Bool, bindings = {} } },
	})

	expect({ success, reason }).toEqual({ false, "InvalidInput" })
	expect(#fixture.writes).toBe(0)
	expect(fixture.owner.GetInput("Primary")).toBeNil()
end)
