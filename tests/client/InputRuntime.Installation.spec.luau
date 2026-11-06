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
local Installation = require(KRF.client.Input.utils.InputInstallation)
local State = require(KRF.client.Input.utils.InputRuntimeState)
local Native = require(KRF.client.Input.utils.NativeInputAdapter)
local Owner = require(KRF.client.Input.InputOwner)
local TestUtils = require(script.Parent.Utils.InputTestUtils)

local fixture: TestUtils.Fixture
local originalNative = Native.new
local originalOwner = Owner.new
local stop: (() -> ())? = nil

beforeEach(function()
	State.Install(nil)
	State.Disconnect()
	fixture = TestUtils.new()

	Native.new = function(): Types.NativeInputAdapter
		return fixture.native
	end
end)

afterEach(function()
	Native.new = originalNative
	Owner.new = originalOwner

	if stop ~= nil then
		stop()
	end

	stop = nil
	State.Install(nil)
	State.Disconnect()
	TestUtils.destroy(fixture)
end)

it("publishes through the stable event only during the installed owner lifetime", function()
	local event = Runtime.OnInput

	stop = Installation.Install(function()
		return true
	end)

	fixture.owner = assert(State.Get(), "Expected installed owner")
	TestUtils.install(fixture)
	TestUtils.enable(fixture)
	local calls: number = 0
	local gestureCalls: number = 0

	event:Connect(function()
		calls += 1
	end)

	Runtime.OnGesture:Connect(function()
		gestureCalls += 1
	end)

	expect(Runtime.SetSource("Gestures", { gestures = { Primary = { Tap = { maxDurationSeconds = 1 } } } })).toBe(true)

	TestUtils.emit(fixture, "Pressed", true)
	expect(calls).toBe(1)
	TestUtils.emit(fixture, "Released", false)
	expect(gestureCalls).toBe(1)
	assert(stop, "Expected cleanup")()
	assert(stop, "Expected cleanup")()
	expect(State.Get()).toBeNil()
	expect(Runtime.OnInput).toBe(event)
	expect(fixture.containerDestroyCalls).toBe(1)
end)

it("rejects a retained old publication callback after a new owner is installed", function()
	local captured: { Types.InputOwnerOptions } = {}

	Owner.new = function(options: Types.InputOwnerOptions): Types.InputOwner
		table.insert(captured, options)

		return originalOwner(options)
	end

	stop = Installation.Install(function()
		return true
	end)

	fixture.owner = assert(State.Get(), "Expected owner")
	assert(stop, "Expected cleanup")()

	stop = Installation.Install(function()
		return true
	end)

	fixture.owner = assert(State.Get(), "Expected replacement owner")

	local calls: number = 0
	local gestureCalls: number = 0

	Runtime.OnInput:Connect(function()
		calls += 1
	end)

	Runtime.OnGesture:Connect(function()
		gestureCalls += 1
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

	captured[1].Publish(sample)
	expect(calls).toBe(0)
	captured[2].Publish(sample)
	expect(calls).toBe(1)

	local gesture: Types.TapGestureEvent = {
		gesture = "Tap",
		inputId = "Primary",
		contextId = "Gameplay",
		timestamp = 1,
		ordinal = 1,
		triggerInputOrdinal = 2,
		recognizedAt = 1,
		pressDurationSeconds = 0.125,
	}

	assert(captured[1].PublishGesture, "Expected gesture publication")(gesture)
	expect(gestureCalls).toBe(0)
	State.Install(nil)
	assert(captured[2].PublishGesture, "Expected gesture publication")(gesture)
	expect(gestureCalls).toBe(0)
	State.Install(fixture.owner)
	assert(captured[2].PublishGesture, "Expected gesture publication")(gesture)
	expect(gestureCalls).toBe(1)

	local sequenceCalls: number = 0
	local recognizerCalls: number = 0

	Runtime.OnSequenceMatched:Connect(function()
		sequenceCalls += 1
	end)

	Runtime.OnRecognizerMatched:Connect(function()
		recognizerCalls += 1
	end)

	local sequence: Types.SequenceMatchEvent = {
		sequenceId = "Combo",
		sourceId = "Manual",
		recognizedAt = 1,
		timestamp = 1,
		ordinal = 1,
		matchedStepCount = 2,
		triggerTokenOrdinal = 1,
	}

	local custom: Types.CustomRecognitionEvent =
		{ recognizerId = "Swipe", sourceId = "Sword", timestamp = 1, ordinal = 1 }

	assert(captured[1].PublishSequence, "Expected sequence publication")(sequence)
	assert(captured[1].PublishRecognizer, "Expected custom publication")(custom)
	expect(sequenceCalls).toBe(0)
	expect(recognizerCalls).toBe(0)
	State.Install(nil)
	assert(captured[2].PublishSequence, "Expected sequence publication")(sequence)
	assert(captured[2].PublishRecognizer, "Expected custom publication")(custom)
	expect(sequenceCalls).toBe(0)
	expect(recognizerCalls).toBe(0)
	State.Install(fixture.owner)
	assert(captured[2].PublishSequence, "Expected sequence publication")(sequence)
	assert(captured[2].PublishRecognizer, "Expected custom publication")(custom)
	expect(sequenceCalls).toBe(1)
	expect(recognizerCalls).toBe(1)
end)

it("contains ordinary observer faults and disconnects public listeners on terminal input failure", function()
	stop = Installation.Install(function()
		return true
	end)

	fixture.owner = assert(State.Get(), "Expected owner")
	TestUtils.install(fixture)
	TestUtils.enable(fixture)

	fixture.owner.ObservePrimitive("Interpretation", function()
		error("PrivateInputFailure")
	end)

	local calls: number = 0

	Runtime.OnInput:Connect(function()
		calls += 1
	end)

	TestUtils.emit(fixture, "Pressed", true)
	expect(calls).toBe(1)

	fixture.owner.ObserveConfigurationCommit(function()
		error("InputSafetyFailure")
	end)

	expect({ Runtime.SetContextEnabled("Gameplay", false) }).toEqual({ false, "InputRuntimeFaulted" })

	State.Notify({
		kind = "Pressed",
		inputId = "Primary",
		contextId = "Gameplay",
		inputType = Enum.InputActionType.Bool,
		value = true,
		timestamp = 2,
		ordinal = 2,
	})

	expect(calls).toBe(1)
	expect({ Runtime.SetSource("Core", {}) }).toEqual({ false, "InputRuntimeFaulted" })
	expect(fixture.connections).toBe(0)
end)
