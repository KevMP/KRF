--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local Types = require(KRF.client.Input.types)
local Native = require(KRF.client.Input.utils.NativeInputAdapter)
local TestUtils = require(script.Parent.Utils.InputTestUtils)

local fixture: TestUtils.Fixture

beforeEach(function()
	fixture = TestUtils.new()
end)

afterEach(function()
	TestUtils.destroy(fixture)
end)

it("creates disabled native contexts under one owned container and destroys only its descendants", function()
	local native: Types.NativeInputAdapter = Native.new(fixture.container)
	local first: InputContext = native.CreateContext("First", { priority = 1000, sink = false })
	local second: InputContext = native.CreateContext("Second", { priority = 2000, sink = true })
	expect(first.Enabled).toBe(false)
	expect(first.Parent).toBe(second.Parent)
	expect(first:IsDescendantOf(fixture.container)).toBe(true)
	native.ConfigureContext(first, { priority = 3000, sink = true }, true)
	expect(first.Enabled).toBe(true)
	expect(first.Priority).toBe(3000)
	expect(first.Sink).toBe(true)
	native.DestroyContainer()
	native.DestroyContainer()
	expect(#fixture.container:GetChildren()).toBe(0)
end)

it("forwards Bool edges and native values without interpreting them or retaining disconnected handlers", function()
	local callbacks: { [string]: (...any) -> () } = {}
	local disconnected: number = 0

	local function signal(kind: string): any
		return {
			Connect = function(_self: any, callback: (...any) -> ()): any
				callbacks[kind] = callback

				return {
					Disconnect = function()
						disconnected += 1
					end,
				}
			end,
		}
	end

	local state: Vector2 = Vector2.new(0.25, 0.75)

	local action: InputAction = {
		Pressed = signal("Pressed"),
		Released = signal("Released"),
		StateChanged = signal("StateChanged"),
		GetState = function()
			return state
		end,
	} :: any

	local native: Types.NativeInputAdapter = Native.new(fixture.container)
	local received: { { any } } = {}

	local stop: () -> () = native.ObserveAction(action, function(kind: Types.NativeTransition, value: any)
		table.insert(received, { kind, value })
	end)

	callbacks.Pressed(true)
	callbacks.Released(true)
	callbacks.StateChanged(state)
	expect(received).toEqual({ { "Pressed", true }, { "Released", false }, { "StateChanged", state } })
	expect(native.ReadState(action)).toBe(state)
	stop()
	expect(disconnected).toBe(3)
end)

it("applies thumbstick response metadata and threshold hysteresis without engine clamping", function()
	local native: Types.NativeInputAdapter = Native.new(fixture.container)
	local context: InputContext = native.CreateContext("Gameplay", { priority = 0, sink = false })

	local direction: InputAction = native.CreateAction(
		"Aim",
		{ context = "Gameplay", type = Enum.InputActionType.Direction2D, bindings = {} },
		context
	)

	local binding: InputBinding = native.CreateBinding(
		"Gamepad",
		{ keyCode = Enum.KeyCode.Thumbstick1, responseCurve = 2, scale = 0.5, vector2Scale = Vector2.one },
		direction
	)

	expect(binding.ResponseCurve).toBe(2)
	expect(binding.Scale).toBe(0.5)

	local action: InputAction = native.CreateAction(
		"Charge",
		{ context = "Gameplay", type = Enum.InputActionType.Bool, bindings = {} },
		context
	)

	local low: InputBinding = native.CreateBinding(
		"Low",
		{ keyCode = Enum.KeyCode.ButtonR2, pressedThreshold = 0.1, releasedThreshold = 0.05 },
		action
	)

	local high: InputBinding = native.CreateBinding(
		"High",
		{ keyCode = Enum.KeyCode.ButtonL2, pressedThreshold = 0.9, releasedThreshold = 0.8 },
		action
	)

	expect(low.PressedThreshold).toBeCloseTo(0.1, 6)
	expect(low.ReleasedThreshold).toBeCloseTo(0.05, 6)
	expect(high.PressedThreshold).toBeCloseTo(0.9, 6)
	expect(high.ReleasedThreshold).toBeCloseTo(0.8, 6)
	native.Destroy(binding)
	expect(binding.Parent).toBeNil()
	native.DestroyContainer()
end)

it("rejects native construction faults without parenting partially configured objects", function()
	local native: Types.NativeInputAdapter = Native.new(fixture.container)
	local context: InputContext = native.CreateContext("Gameplay", { priority = 0, sink = false })

	local action: InputAction = native.CreateAction(
		"Primary",
		{ context = "Gameplay", type = Enum.InputActionType.Bool, bindings = {} },
		context
	)

	local success: boolean = pcall(native.CreateBinding, "Broken", { keyCode = "Invalid" } :: any, action)
	expect(success).toBe(false)
	expect(#action:GetChildren()).toBe(0)
	native.DestroyContainer()
	local unavailable: Types.NativeInputAdapter = Native.new()
	local created: boolean, reason: any = pcall(unavailable.CreateContext, "Missing", { priority = 0, sink = false })
	expect(created).toBe(false)
	expect(string.find(tostring(reason), "LocalPlayerUnavailable", 1, true) ~= nil).toBe(true)
	unavailable.DestroyContainer()
end)
