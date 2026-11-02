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

it("rejects mutations before readiness without constructing native instances", function()
	fixture.ready = false
	expect({ fixture.owner.SetSource("Core", TestUtils.definition()) }).toEqual({ false, "ClientNotReady" })
	expect({ fixture.owner.RemoveSource("Core") }).toEqual({ false, "ClientNotReady" })
	expect({ fixture.owner.SetContextEnabled("Gameplay", true) }).toEqual({ false, "ClientNotReady" })
	expect(#fixture.writes).toBe(0)
end)

it("destroys an unused owner once and rejects later mutations", function()
	fixture.owner.Destroy()
	fixture.owner.Destroy()
	expect(fixture.containerDestroyCalls).toBe(1)
	expect({ fixture.owner.SetSource("Core", TestUtils.definition()) }).toEqual({ false, "ClientNotReady" })
	expect(fixture.owner.GetInput("Primary")).toBeNil()
	expect(#fixture.events).toBe(0)
end)

it("disconnects native and private observers and bars retained callbacks after destruction", function()
	TestUtils.install(fixture)
	TestUtils.enable(fixture)
	local observed: number = 0

	fixture.owner.ObservePrimitive("Routing", function()
		observed += 1
	end)

	local callback = fixture.callbacks[fixture.actions.Primary]
	fixture.owner.Destroy()
	callback("Pressed", true)
	expect(fixture.connections).toBe(0)
	expect(#fixture.events).toBe(0)
	expect(observed).toBe(0)
	expect(fixture.owner.GetContext("Gameplay")).toBeNil()
	expect(fixture.owner.GetEffectiveBindings("Primary")).toBeNil()
	expect(fixture.containerDestroyCalls).toBe(1)
end)

it("returns native and observer counts to baseline through repeated source churn", function()
	for _iteration: number = 1, 30 do
		TestUtils.install(fixture)
		TestUtils.enable(fixture)
		TestUtils.emit(fixture, "Pressed", true)
		expect(fixture.owner.RemoveSource("Core")).toBe(true)
		expect(#fixture.container:GetDescendants()).toBe(0)
		expect(fixture.connections).toBe(0)
		expect(fixture.owner.GetContext("Gameplay")).toBeNil()
	end

	expect(#fixture.events).toBe(60)
end)
