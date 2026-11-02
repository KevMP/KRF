--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local Types = require(ReplicatedStorage.Packages.KRF.client.Input.types)
local Utils = require(script.Parent.Utils.GestureTestUtils)
local fixture: Utils.Fixture

beforeEach(function()
	fixture = Utils.new()
end)

afterEach(function()
	Utils.destroy(fixture)
end)

for _, duration: number in { 0, 0.125, 0.25, 0.250001 } do
	it("classifies a genuine Tap at duration " .. tostring(duration), function()
		expect({ Utils.install(fixture, { Tap = { maxDurationSeconds = 0.25 } }) }).toEqual({ true })
		Utils.tap(fixture, 0, duration)
		expect(Utils.kinds(fixture)).toEqual(if duration <= 0.25 then { "Tap" } else {})

		if duration <= 0.25 then
			local event: Types.GestureEvent = fixture.events[1]
			assert(event.gesture == "Tap", "Expected Tap variant")
			expect(event.pressDurationSeconds).toBe(duration)
			expect(event.recognizedAt).toBe(duration)
			expect(event.timestamp).toBe(duration)
			expect(event.triggerInputOrdinal).toBe(fixture.input.events[2].ordinal)
		end
	end)
end

it("ignores unmatched and duplicate native transitions without duplicate recognition", function()
	expect(Utils.install(fixture, { Tap = { maxDurationSeconds = 0.25 } })).toBe(true)
	Utils.emit(fixture, 0, "Released")
	Utils.emit(fixture, 0, "Pressed")
	Utils.emit(fixture, 0.0625, "Pressed")
	Utils.emit(fixture, 0.125, "Released")
	Utils.emit(fixture, 0.125, "Released")
	expect(Utils.kinds(fixture)).toEqual({ "Tap" })
	expect(#fixture.input.events).toBe(2)
end)

it("wakes Held and LongHeld once each without more native input", function()
	expect(Utils.install(fixture, { Held = { afterSeconds = 0.25 }, LongHeld = { afterSeconds = 0.5 } })).toBe(true)
	Utils.emit(fixture, 0, "Pressed")
	expect(Utils.pending(fixture) > 0).toBe(true)
	Utils.wake(fixture, 0.249)
	expect(Utils.kinds(fixture)).toEqual({})
	Utils.wake(fixture, 0.25)
	expect(Utils.kinds(fixture)).toEqual({ "Held" })
	Utils.wake(fixture, 0.5)
	Utils.wake(fixture, 10)
	expect(Utils.kinds(fixture)).toEqual({ "Held", "LongHeld" })
	expect(Utils.pending(fixture)).toBe(0)
	local event: Types.GestureEvent = fixture.events[1]
	assert(event.gesture == "Held", "Expected Held variant")
	expect(event.thresholdSeconds).toBe(0.25)
	expect(event.elapsedSeconds).toBe(0.25)
	expect(event.triggerInputOrdinal).toBe(fixture.input.events[1].ordinal)
end)

it("allows LongHeld alone and reports actual late emission time", function()
	expect(Utils.install(fixture, { LongHeld = { afterSeconds = 0.5 } })).toBe(true)
	Utils.emit(fixture, 0, "Pressed")
	Utils.wake(fixture, 2)
	expect(Utils.kinds(fixture)).toEqual({ "LongHeld" })
	local event: Types.GestureEvent = fixture.events[1]
	assert(event.gesture == "LongHeld", "Expected LongHeld variant")
	expect(event.timestamp).toBe(2)
	expect(event.thresholdSeconds).toBe(0.5)
	expect(event.elapsedSeconds).toBe(2)
end)

for _, time: number in { 0.25, 0.5, 2 } do
	it("settles due holds before independent Tap on release at " .. tostring(time), function()
		expect(Utils.install(fixture, {
			Tap = { maxDurationSeconds = 3 },
			Held = { afterSeconds = 0.25 },
			LongHeld = { afterSeconds = 0.5 },
		})).toBe(true)

		Utils.tap(fixture, 0, time)
		expect(Utils.kinds(fixture)).toEqual(if time < 0.5 then { "Held", "Tap" } else { "Held", "LongHeld", "Tap" })
		Utils.wake(fixture, 10)
		expect(#fixture.events).toBe(if time < 0.5 then 2 else 3)
	end)
end

it("keeps a foreign Held independent from Tap even after release catch-up", function()
	expect(Utils.install(fixture, { Tap = { maxDurationSeconds = 0.25 } }, "TapOwner")).toBe(true)
	expect(Utils.install(fixture, { Held = { afterSeconds = 0.125 } }, "HoldOwner")).toBe(true)
	Utils.tap(fixture, 0, 0.1875)
	expect(Utils.kinds(fixture)).toEqual({ "Held", "Tap" })
end)

for _, kind: string in { "Held", "LongHeld" } do
	it("suppresses same-source Tap after the explicit " .. kind .. " threshold", function()
		local definitions: any = { Tap = { maxDurationSeconds = 0.5, suppressIfHoldRecognized = true } }
		definitions[kind] = { afterSeconds = 0.25 }
		expect(Utils.install(fixture, definitions)).toBe(true)
		Utils.tap(fixture, 0, 0.25)
		expect(Utils.kinds(fixture)).toEqual({ kind })
	end)
end

it("recognizes short Tap before its owner's hold threshold", function()
	expect(
		Utils.install(
			fixture,
			{ Tap = { maxDurationSeconds = 0.5, suppressIfHoldRecognized = true }, Held = { afterSeconds = 0.25 } }
		)
	).toBe(true)

	Utils.tap(fixture, 0, 0.125)
	Utils.wake(fixture, 1)
	expect(Utils.kinds(fixture)).toEqual({ "Tap" })
end)

it("never catches up overdue holds or fabricates Tap on context cancellation", function()
	expect(Utils.install(fixture, { Tap = { maxDurationSeconds = 3 }, Held = { afterSeconds = 0.25 } })).toBe(true)
	Utils.emit(fixture, 0, "Pressed")
	fixture.input.now = 2
	fixture.input.syntheticEnd = true
	expect(fixture.input.owner.SetContextEnabled("Gameplay", false)).toBe(true)
	Utils.wake(fixture, 10)
	expect(Utils.kinds(fixture)).toEqual({})
	expect(fixture.input.events[2].kind).toBe("Cancelled")
	expect(Utils.pending(fixture)).toBe(0)
end)
