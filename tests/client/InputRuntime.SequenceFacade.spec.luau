--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local Types = require(ReplicatedStorage.Packages.KRF.client.Input.types)
local Runtime: Types.InputRuntime = require(ReplicatedStorage.Packages.KRF.client.Input.InputRuntime)
local State = require(ReplicatedStorage.Packages.KRF.client.Input.utils.InputRuntimeState)
local Utils = require(script.Parent.Utils.SequenceTestUtils)
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

it("keeps stable read-only sequence/custom events and hides private dispatch/reset APIs", function()
	expect(table.isfrozen(Runtime)).toBe(true)
	local sequenceEvent = Runtime.OnSequenceMatched
	local recognizerEvent = Runtime.OnRecognizerMatched

	for _, event in { sequenceEvent, recognizerEvent } do
		local writable: boolean = pcall(function()
			return (event :: any).Fire
		end)

		expect(writable).toBe(false)
	end

	expect((Runtime :: any).ObserveCandidateEnvelope).toBeNil()
	expect((Runtime :: any).ResetRecognition).toBeNil()
	State.Install(nil)
	expect(Runtime.GetSequence("Combo")).toBeNil()
	expect(Runtime.GetRecognizer("Swipe")).toBeNil()
	State.Install(fixture.input.owner)
	expect(Runtime.GetSequence("Unknown")).toBeNil()
	expect(Runtime.GetRecognizer("Unknown")).toBeNil()
	expect(Runtime.OnSequenceMatched).toBe(sequenceEvent)
	expect(Runtime.OnRecognizerMatched).toBe(recognizerEvent)
end)

it("disconnects old lifetime subscriptions while preserving public event identity", function()
	local oldCalls: number = 0
	local newCalls: number = 0

	Runtime.OnSequenceMatched:Connect(function()
		oldCalls += 1
	end)

	Runtime.OnRecognizerMatched:Connect(function()
		oldCalls += 1
	end)

	State.Disconnect()

	Runtime.OnSequenceMatched:Connect(function()
		newCalls += 1
	end)

	Runtime.OnRecognizerMatched:Connect(function()
		newCalls += 1
	end)

	State.NotifySequence(table.freeze({
		sequenceId = "Combo",
		sourceId = "Manual",
		recognizedAt = 0,
		timestamp = 0,
		ordinal = 1,
		matchedStepCount = 1,
		triggerTokenOrdinal = 1,
	}))

	State.NotifyRecognizer(table.freeze({ recognizerId = "Swipe", sourceId = "Custom", timestamp = 0, ordinal = 1 }))
	expect(oldCalls).toBe(0)
	expect(newCalls).toBe(2)
	State.Disconnect()
end)

it("delegates inspection to the installed owner and returns nil after teardown", function()
	State.Install(fixture.input.owner)
	expect({ Runtime.SetSource("Manual", { sequences = { Combo = Utils.pattern({ "X" }) } }) }).toEqual({ true })
	expect(assert(Runtime.GetSequence("Combo")).sourceId).toBe("Manual")
	State.Install(nil)
	expect(Runtime.GetSequence("Combo")).toBeNil()
end)
