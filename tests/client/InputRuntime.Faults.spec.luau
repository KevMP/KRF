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

it("rejects a native write fault with the previous graph intact when restoration is provable", function()
	TestUtils.install(fixture)
	TestUtils.enable(fixture)
	local context: InputContext = fixture.contexts.Gameplay

	fixture.failAt[#fixture.writes + 1] = true
	local success: boolean, reason: string? = fixture.owner.SetContextEnabled("Gameplay", false)
	expect({ success, reason }).toEqual({ false, "NativeCommitFailed" })
	expect((assert(fixture.owner.GetContext("Gameplay"), "Expected installed context")).enabled).toBe(true)
	expect(context.Enabled).toBe(true)
	expect((assert(fixture.owner.GetInput("Primary"), "Expected installed input")).sourceId).toBe("Core")
	expect(#fixture.events).toBe(0)
end)

it("fails closed when native application and restoration both fail", function()
	TestUtils.install(fixture)
	local before: number = #fixture.writes

	fixture.onWrite = function(operation: string)
		if operation == "ConfigureContext:Gameplay" then
			fixture.contexts.Gameplay.Enabled = true
			error("PartialNativeWrite", 0)
		end
	end

	local success: boolean, reason: string? = fixture.owner.SetContextEnabled("Gameplay", true)
	fixture.onWrite = nil
	expect({ success, reason }).toEqual({ false, "InputRuntimeFaulted" })
	expect(#fixture.writes > before).toBe(true)
	expect(#fixture.container:GetDescendants()).toBe(0)
	expect(fixture.connections).toBe(0)
	expect(fixture.owner.GetInput("Primary")).toBeNil()
	expect({ fixture.owner.SetSource("Later", {}) }).toEqual({ false, "InputRuntimeFaulted" })
end)
