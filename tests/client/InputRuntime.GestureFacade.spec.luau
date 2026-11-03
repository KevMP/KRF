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
local Utils = require(script.Parent.Utils.GestureTestUtils)
local fixture: Utils.Fixture

beforeEach(function()
	State.Install(nil)
	State.Disconnect()
	fixture = Utils.new()
end)

afterEach(function()
	State.Install(nil)
	State.Disconnect()
	Utils.destroy(fixture)
end)

it("exposes a stable read-only gesture Event and hides recognition state and reset operations", function()
	expect(table.isfrozen(Runtime)).toBe(true)

	local writableEvent: boolean = pcall(function()
		return (Runtime.OnGesture :: any).Fire
	end)

	expect(writableEvent).toBe(false)

	expect((Runtime :: any).ResetRecognition).toBeNil()
	expect((Runtime :: any).PrepareRecognitionReset).toBeNil()
	expect((Runtime :: any).ObserveDispatchGroup).toBeNil()
	expect(Runtime.GetGestures("Primary")).toBeNil()
end)

it("delegates configured gesture inspection and drops old subscriptions between owner lifetimes", function()
	local event = Runtime.OnGesture
	local oldCalls: number = 0

	event:Connect(function()
		oldCalls += 1
	end)

	State.Disconnect()
	State.Install(fixture.input.owner)
	expect(Runtime.SetSource("Gestures", { gestures = { Primary = Utils.pair() } })).toBe(true)
	expect(assert(Runtime.GetGestures("Primary"), "Expected gestures").Tap.sourceId).toBe("Gestures")
	local newCalls: number = 0

	event:Connect(function()
		newCalls += 1
	end)

	local sample: Types.GestureEvent = table.freeze({
		gesture = "Tap" :: "Tap",
		inputId = "Primary",
		contextId = "Gameplay",
		timestamp = 1,
		ordinal = 1,
		triggerInputOrdinal = 2,
		recognizedAt = 1,
		pressDurationSeconds = 0.125,
	})

	State.NotifyGesture(sample)

	expect(Runtime.OnGesture).toBe(event)
	expect(oldCalls).toBe(0)
	expect(newCalls).toBe(1)
end)
