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

for _, timerFirst: boolean in { true, false } do
	it("lets a second press at the inclusive boundary win with timerFirst=" .. tostring(timerFirst), function()
		expect(Utils.install(fixture, Utils.pair("DeferredTap"))).toBe(true)
		Utils.tap(fixture, 0, 0.125)
		expect(Utils.kinds(fixture)).toEqual({})

		if timerFirst then
			Utils.wake(fixture, 0.625)
		end

		Utils.emit(fixture, 0.625, "Pressed")

		if not timerFirst then
			Utils.wake(fixture, 0.625)
		end

		expect(Utils.kinds(fixture)).toEqual({ "DoubleTapped" })
		Utils.emit(fixture, 0.75, "Released")
		Utils.wake(fixture, 5)
		expect(Utils.kinds(fixture)).toEqual({ "DoubleTapped" })
		expect(#fixture.input.events).toBe(4)
		expect(Utils.pending(fixture)).toBe(0)
	end)
end

it("emits one delayed Tap strictly after the gap with original release metadata", function()
	expect(Utils.install(fixture, Utils.pair("DeferredTap"))).toBe(true)
	Utils.tap(fixture, 0, 0.125)
	expect(Utils.pending(fixture) > 0).toBe(true)
	Utils.wake(fixture, 0.625)
	expect(Utils.kinds(fixture)).toEqual({})
	Utils.wake(fixture, 0.75)
	Utils.wake(fixture, 2)
	expect(Utils.kinds(fixture)).toEqual({ "Tap" })
	local event: Types.GestureEvent = fixture.events[1]
	assert(event.gesture == "Tap", "Expected Tap variant")
	expect(event.timestamp).toBe(0.75)
	expect(event.recognizedAt).toBe(0.125)
	expect(event.pressDurationSeconds).toBe(0.125)
	expect(event.triggerInputOrdinal).toBe(fixture.input.events[2].ordinal)
	expect(Utils.pending(fixture)).toBe(0)
end)

it("rearms early and equal wakeups beyond the boundary without a tight retry", function()
	expect(Utils.install(fixture, Utils.pair("DeferredTap"))).toBe(true)
	Utils.tap(fixture, 0, 0.125)
	expect(#fixture.jobs > 0).toBe(true)
	local first: Utils.Job = fixture.jobs[#fixture.jobs]

	fixture.input.now = 0.5
	first.fired = true
	first.callback()
	expect(Utils.kinds(fixture)).toEqual({})
	expect(#fixture.jobs <= 3).toBe(true)
	Utils.wake(fixture, 0.625)

	local equalWake: Utils.Job = fixture.jobs[#fixture.jobs]
	equalWake.fired = true
	equalWake.callback()
	local active: number = 0

	for _, job: Utils.Job in fixture.jobs do
		if not job.cancelled and not job.fired then
			active += 1
			expect(job.deadline > 0.625).toBe(true)
		end
	end

	expect(active).toBe(1)
	Utils.wake(fixture, 0.75)
	expect(Utils.kinds(fixture)).toEqual({ "Tap" })
end)

it("expires old Tap before a new press outside the gap when the scheduler stalls", function()
	expect(Utils.install(fixture, Utils.pair("DeferredTap"))).toBe(true)
	Utils.tap(fixture, 0, 0.125)
	Utils.emit(fixture, 1, "Pressed")
	expect(Utils.kinds(fixture)).toEqual({ "Tap" })
	expect(fixture.events[1].timestamp).toBe(1)
	expect(Utils.candidates(fixture.groups[#fixture.groups])).toEqual({ "Pressed" })
	Utils.emit(fixture, 1.125, "Released")
	Utils.wake(fixture, 2)
	expect(Utils.kinds(fixture)).toEqual({ "Tap", "Tap" })
end)

it("keeps later holds alive after consuming the paired single Tap", function()
	local definitions: Types.GestureDefinitions = Utils.pair("DeferredTap")
	definitions.Held = { afterSeconds = 0.5 }
	expect(Utils.install(fixture, definitions)).toBe(true)
	Utils.tap(fixture, 0, 0.125)
	Utils.emit(fixture, 0.25, "Pressed")
	Utils.wake(fixture, 0.75)
	expect(Utils.kinds(fixture)).toEqual({ "DoubleTapped", "Held" })
end)
