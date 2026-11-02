--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local Types = require(KRF.client.Input.types)
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

it("fails closed when native rollback cannot restore the original held state", function()
	TestUtils.install(fixture)
	TestUtils.enable(fixture)
	TestUtils.emit(fixture, "Pressed", true)
	local original = fixture.native.ConfigureContext
	local first: boolean = true

	fixture.native.ConfigureContext = function(
		context: InputContext,
		definition: Types.ContextDefinition,
		enabled: boolean
	): ()
		if first then
			first = false
			fixture.states[fixture.actions.Primary] = false
			error("LostNativeEpoch")
		end

		original(context, definition, enabled)
	end

	expect({ fixture.owner.SetContextEnabled("Gameplay", false) }).toEqual({ false, "InputRuntimeFaulted" })
	expect(fixture.owner.GetInput("Primary")).toBeNil()
	expect(fixture.connections).toBe(0)
end)

it("publishes terminal validity to surviving safety observers before releasing the owner", function()
	TestUtils.install(fixture)
	local changes: { Types.InputGraphChange } = {}

	fixture.owner.ObserveConfigurationCommit(function(change: Types.InputGraphChange)
		table.insert(changes, change)
	end)

	fixture.native.Destroy = function(_instance: Instance): ()
		error("NativeRetirementFailure")
	end

	expect({ fixture.owner.RemoveSource("Core") }).toEqual({ false, "InputRuntimeFaulted" })
	expect(#changes).toBe(1)
	expect(changes[1].reasons).toEqual({ "InputRuntimeFaulted" })
	expect(changes[1].next.inputs).toEqual({})
	expect(fixture.owner.GetInput("Primary")).toBeNil()
end)

afterEach(function()
	TestUtils.destroy(fixture)
end)

it("rolls back staged native allocations when construction fails before publication", function()
	fixture.failAt[3] = true
	expect({ fixture.owner.SetSource("Core", TestUtils.definition()) }).toEqual({ false, "NativeCommitFailed" })
	expect(#fixture.container:GetDescendants()).toBe(0)
	expect(fixture.owner.GetInput("Primary")).toBeNil()
	expect(fixture.connections).toBe(0)
	fixture.failAt = {}
	TestUtils.install(fixture)
	expect(fixture.connections).toBe(1)
end)

it("fails closed when staged allocation cleanup cannot be confirmed", function()
	fixture.failAt[3] = true
	fixture.failAt[4] = true
	expect({ fixture.owner.SetSource("Core", TestUtils.definition()) }).toEqual({ false, "InputRuntimeFaulted" })
	expect(#fixture.container:GetDescendants()).toBe(0)
	expect(fixture.connections).toBe(0)
end)

it("fails closed when retiring obsolete native objects faults after installation", function()
	TestUtils.install(fixture)
	local destroy = fixture.native.Destroy

	fixture.native.Destroy = function(_instance: Instance): ()
		error("NativeDestroyFailure")
	end

	local success: boolean, reason: string? = fixture.owner.RemoveSource("Core")
	fixture.native.Destroy = destroy
	expect({ success, reason }).toEqual({ false, "InputRuntimeFaulted" })
	expect(fixture.connections).toBe(0)
	expect(#fixture.container:GetDescendants()).toBe(0)
end)

it("restores display metadata along with a failed native context edit", function()
	TestUtils.install(fixture)
	local action: InputAction = fixture.actions.Primary

	local definition: TestUtils.CoreDefinition = TestUtils.definition()
	definition.inputs.Primary.displayName = "Renamed"
	definition.contexts.Gameplay.priority = 2500
	fixture.failAt[#fixture.writes + 1] = true
	expect({ fixture.owner.SetSource("Core", definition) }).toEqual({ false, "NativeCommitFailed" })
	expect(action.DisplayName).toBe("Primary")
	expect(assert(fixture.owner.GetInput("Primary"), "Expected input").displayName).toBeNil()
end)

it("removes one binding slot and preserves the other native binding and action", function()
	TestUtils.install(fixture)
	local action: InputAction = fixture.actions.Primary
	local gamepad: InputBinding = fixture.bindings["Primary:Gamepad"]
	local keyboard: InputBinding = fixture.bindings["Primary:Keyboard"]

	local definition: TestUtils.CoreDefinition = TestUtils.definition()
	definition.inputs.Primary.bindings.Keyboard = nil
	expect(fixture.owner.SetSource("Core", definition)).toBe(true)
	expect(fixture.actions.Primary).toBe(action)
	expect(fixture.bindings["Primary:Gamepad"]).toBe(gamepad)
	expect(keyboard.Parent).toBeNil()
	expect(assert(fixture.owner.GetEffectiveBindings("Primary"), "Expected bindings").Keyboard).toBeNil()
end)
