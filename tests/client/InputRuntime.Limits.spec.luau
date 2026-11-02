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
local TestUtils = require(script.Parent.Utils.InputTestUtils)

local fixture: TestUtils.Fixture

beforeEach(function()
	fixture = TestUtils.new()
end)

afterEach(function()
	TestUtils.destroy(fixture)
end)

it("accepts the source budget and rejects one more source before mutation", function()
	TestUtils.install(fixture)

	for index: number = 2, Constants.MAX_SOURCES do
		expect(fixture.owner.SetSource("Source" .. index, {
			inputs = {
				["Input" .. index] = {
					context = "Gameplay",
					type = Enum.InputActionType.Bool,
					bindings = { Keyboard = { keyCode = Enum.KeyCode.Q } },
				},
			},
		})).toBe(true)
	end

	local before: number = #fixture.writes

	expect({
		fixture.owner.SetSource("Overflow", {
			inputs = {
				Extra = {
					context = "Gameplay",
					type = Enum.InputActionType.Bool,
					bindings = { Keyboard = { keyCode = Enum.KeyCode.Q } },
				},
			},
		}),
	}).toEqual({ false, "InputSourceLimitExceeded" })

	expect(#fixture.writes).toBe(before)
	expect(fixture.owner.RemoveSource("Source2")).toBe(true)
	expect(fixture.owner.SetSource("Overflow", { contexts = { Extra = { priority = 0, sink = false } } })).toBe(true)
end)

it("accepts the context budget and rejects one above it without replacing the live graph", function()
	local definition: TestUtils.CoreDefinition = { contexts = {}, inputs = {} }

	for index: number = 1, Constants.MAX_CONTEXTS do
		definition.contexts["Context" .. index] = { priority = index, sink = false }
	end

	TestUtils.install(fixture, definition)
	local before: number = #fixture.writes
	local index: number = Constants.MAX_CONTEXTS + 1

	definition.contexts["Context" .. index] = { priority = index, sink = false }
	expect({ fixture.owner.SetSource("Core", definition) }).toEqual({ false, "InputContextLimitExceeded" })
	expect(#fixture.writes).toBe(before)
end)

it("accepts the input budget and rejects one above it without replacing the live graph", function()
	local definition: TestUtils.CoreDefinition =
		{ contexts = { Gameplay = { priority = 0, sink = false } }, inputs = {} }

	for index: number = 1, Constants.MAX_INPUTS do
		definition.inputs["Input" .. index] = { context = "Gameplay", type = Enum.InputActionType.Bool, bindings = {} }
	end

	TestUtils.install(fixture, definition)
	local before: number = #fixture.writes
	local index: number = Constants.MAX_INPUTS + 1

	definition.inputs["Input" .. index] = { context = "Gameplay", type = Enum.InputActionType.Bool, bindings = {} }
	expect({ fixture.owner.SetSource("Core", definition) }).toEqual({ false, "InputLimitExceeded" })
	expect(#fixture.writes).toBe(before)
end)

it("accepts the binding budget and rejects one above it without replacing the live graph", function()
	local definition: TestUtils.CoreDefinition = TestUtils.definition()
	definition.inputs.Primary.bindings = {}

	for index: number = 1, Constants.MAX_BINDINGS do
		definition.inputs.Primary.bindings["Slot" .. index] = { keyCode = Enum.KeyCode.Q }
	end

	TestUtils.install(fixture, definition)
	local before: number = #fixture.writes
	local index: number = Constants.MAX_BINDINGS + 1

	definition.inputs.Primary.bindings["Slot" .. index] = { keyCode = Enum.KeyCode.Q }
	expect({ fixture.owner.SetSource("Core", definition) }).toEqual({ false, "InputBindingLimitExceeded" })
	expect(#fixture.writes).toBe(before)
end)

it("bounds stored overlays including shadowed declarations", function()
	local definition: TestUtils.CoreDefinition = TestUtils.definition()
	definition.inputs.Primary.bindings = {}

	local slots: { [string]: Types.BindingDefinition } = {}

	for index: number = 1, Constants.MAX_OVERRIDES / 2 do
		definition.inputs.Primary.bindings["Slot" .. index] = { keyCode = Enum.KeyCode.Q }
		slots["Slot" .. index] = { keyCode = Enum.KeyCode.E }
	end

	TestUtils.install(fixture, definition)
	expect(fixture.owner.SetSource("Low", { priority = 1, bindingOverrides = { Primary = slots } })).toBe(true)
	expect(fixture.owner.SetSource("High", { priority = 2, bindingOverrides = { Primary = slots } })).toBe(true)
	local before: number = #fixture.writes

	expect({
		fixture.owner.SetSource(
			"Overflow",
			{ priority = 3, bindingOverrides = { Primary = { Slot1 = { keyCode = Enum.KeyCode.R } } } }
		),
	}).toEqual({ false, "InputOverrideLimitExceeded" })

	expect(#fixture.writes).toBe(before)
end)

it("bounds primitive observers and releases capacity on disconnect", function()
	local stops: { () -> () } = {}

	for _index: number = 1, Constants.MAX_PRIMITIVE_OBSERVERS do
		table.insert(stops, fixture.owner.ObservePrimitive("Routing", function() end))
	end

	local success: boolean, reason: any = pcall(function()
		fixture.owner.ObservePrimitive("Routing", function() end)
	end)

	expect(success).toBe(false)
	expect(string.find(tostring(reason), "InputObserverLimitExceeded", 1, true) ~= nil).toBe(true)
	stops[1]()

	expect(pcall(function()
		fixture.owner.ObservePrimitive("Routing", function() end)
	end)).toBe(true)
end)

it("bounds graph validators and releases capacity on disconnect", function()
	local stops: { () -> () } = {}

	for _index: number = 1, Constants.MAX_GRAPH_VALIDATORS do
		table.insert(
			stops,
			fixture.owner.RegisterGraphValidator(function()
				return true, nil
			end)
		)
	end

	local success: boolean, reason: any = pcall(function()
		fixture.owner.RegisterGraphValidator(function()
			return true, nil
		end)
	end)

	expect(success).toBe(false)
	expect(string.find(tostring(reason), "InputValidatorLimitExceeded", 1, true) ~= nil).toBe(true)
	stops[1]()

	expect(pcall(function()
		fixture.owner.RegisterGraphValidator(function()
			return true, nil
		end)
	end)).toBe(true)
end)

it("bounds commit observers and releases capacity on disconnect", function()
	local stops: { () -> () } = {}

	for _index: number = 1, Constants.MAX_COMMIT_OBSERVERS do
		table.insert(stops, fixture.owner.ObserveConfigurationCommit(function() end))
	end

	local success: boolean, reason: any = pcall(function()
		fixture.owner.ObserveConfigurationCommit(function() end)
	end)

	expect(success).toBe(false)
	expect(string.find(tostring(reason), "InputCommitObserverLimitExceeded", 1, true) ~= nil).toBe(true)
	stops[1]()

	expect(pcall(function()
		fixture.owner.ObserveConfigurationCommit(function() end)
	end)).toBe(true)
end)
