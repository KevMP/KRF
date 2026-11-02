--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local Types = require(KRF.client.Input.types)
local Runtime: Types.InputRuntime = require(KRF.client.Input.InputRuntime)
local State = require(KRF.client.Input.utils.InputRuntimeState)
local GoodSignal: any = require(KRF.shared.Signal.GoodSignal)
local TestUtils = require(script.Parent.Utils.InputTestUtils)

local fixture: TestUtils.Fixture
local originalFire: any = GoodSignal.Fire

beforeEach(function()
	State.Install(nil)
	State.Disconnect()
	fixture = TestUtils.new()
end)

afterEach(function()
	GoodSignal.Fire = originalFire
	State.Install(nil)
	State.Disconnect()
	TestUtils.destroy(fixture)
end)

it("runs private routing before public Fire even when public scheduling is withheld", function()
	State.Install(fixture.owner)
	TestUtils.install(fixture)
	TestUtils.enable(fixture)
	fixture.onPublish = State.Notify

	local order: { string } = {}
	local publicCalls: number = 0

	Runtime.OnInput:Connect(function()
		publicCalls += 1
	end)

	fixture.owner.ObservePrimitive("Routing", function()
		table.insert(order, "Routing")
	end)

	GoodSignal.Fire = function()
		table.insert(order, "Fire")
	end

	TestUtils.emit(fixture, "Pressed", true)
	expect(order).toEqual({ "Routing", "Fire" })
	expect(publicCalls).toBe(0)
end)

it("exports a frozen facade and read-only event without private owner operations", function()
	expect(table.isfrozen(Runtime)).toBe(true)

	expect(pcall(function()
		(Runtime :: any).SetSource = function() end
	end)).toBe(false)

	expect(pcall(function()
		return (Runtime.OnInput :: any).Fire
	end)).toBe(false)

	expect((Runtime :: any).RegisterGraphValidator).toBeNil()
	expect((Runtime :: any).ObservePrimitive).toBeNil()
	expect((Runtime :: any).PrepareEpochInvalidation).toBeNil()
	expect((Runtime :: any).Init).toBeNil()
end)

it("rejects every mutation and returns absent queries before owner installation", function()
	local label: InputActionLabel = Instance.new("InputActionLabel")
	label.Parent = fixture.container
	expect({ Runtime.SetSource("Core", TestUtils.definition()) }).toEqual({ false, "ClientNotReady" })
	expect({ Runtime.RemoveSource("Core") }).toEqual({ false, "ClientNotReady" })
	expect({ Runtime.SetContextEnabled("Gameplay", true) }).toEqual({ false, "ClientNotReady" })
	expect({ Runtime.BindActionLabel("Primary", label) }).toEqual({ false, "ClientNotReady" })
	expect({ Runtime.UnbindActionLabel(label) }).toEqual({ false, "ClientNotReady" })
	expect(Runtime.GetInput("Primary")).toBeNil()
	expect(Runtime.GetContext("Gameplay")).toBeNil()
	expect(Runtime.GetEffectiveBindings("Primary")).toBeNil()
	expect(#fixture.writes).toBe(0)
end)

it("delegates source context and label operations to the installed owner", function()
	State.Install(fixture.owner)
	expect(Runtime.SetSource("Core", TestUtils.definition())).toBe(true)
	expect(Runtime.SetContextEnabled("Gameplay", true)).toBe(true)
	expect(assert(Runtime.GetInput("Primary"), "Expected installed input").sourceId).toBe("Core")
	expect(assert(Runtime.GetContext("Gameplay"), "Expected installed context").enabled).toBe(true)

	expect(assert(Runtime.GetEffectiveBindings("Primary"), "Expected effective bindings").Keyboard.definition.keyCode).toBe(
		Enum.KeyCode.Q
	)

	local label: InputActionLabel = Instance.new("InputActionLabel")
	label.Parent = fixture.container
	expect(Runtime.BindActionLabel("Primary", label)).toBe(true)
	expect(label.InputAction).toBe(fixture.actions.Primary)
	expect(Runtime.UnbindActionLabel(label)).toBe(true)
	expect(Runtime.RemoveSource("Core")).toBe(true)
	expect(Runtime.GetInput("Primary")).toBeNil()
end)

it("retains event identity across uninstall and drops old subscriptions before a new lifetime", function()
	local event = Runtime.OnInput
	State.Install(fixture.owner)
	local oldCalls: number = 0

	local connection = event:Connect(function()
		oldCalls += 1
	end)

	State.Install(nil)
	State.Disconnect()
	State.Install(fixture.owner)
	local newCalls: number = 0

	event:Connect(function()
		newCalls += 1
	end)

	local sample: Types.SemanticInputEvent = {
		kind = "Pressed",
		inputId = "Primary",
		contextId = "Gameplay",
		inputType = Enum.InputActionType.Bool,
		value = true,
		timestamp = 1,
		ordinal = 1,
	}

	State.Notify(table.freeze(sample))

	expect(Runtime.OnInput).toBe(event)
	connection:Disconnect()
	expect(oldCalls).toBe(0)
	expect(newCalls).toBe(1)
end)

it("lets public subscribers yield without delaying synchronous primitive observers", function()
	State.Install(fixture.owner)
	TestUtils.install(fixture)
	TestUtils.enable(fixture)
	local routed: boolean = false
	local publicEntered: boolean = false
	local publicThread: thread? = nil

	fixture.onPublish = State.Notify

	fixture.owner.ObservePrimitive("Routing", function()
		routed = true
	end)

	Runtime.OnInput:Connect(function()
		publicEntered = true
		expect(routed).toBe(true)
		publicThread = coroutine.running()
		coroutine.yield()
	end)

	TestUtils.emit(fixture, "Pressed", true)

	if publicThread ~= nil then
		coroutine.close(publicThread)
	end

	expect(routed).toBe(true)
	expect(publicEntered).toBe(true)
	expect(#fixture.events).toBe(1)
end)
