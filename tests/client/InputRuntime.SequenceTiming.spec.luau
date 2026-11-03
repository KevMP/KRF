--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local Utils = require(script.Parent.Utils.SequenceTestUtils)
local fixture: Utils.Fixture

beforeEach(function()
	fixture = Utils.new()
end)

afterEach(function()
	Utils.destroy(fixture)
end)

for _, entry in
	{
		{ gap = 0.5, total = 1, times = { 0, 0.5, 1 }, matches = true },
		{ gap = 0.5, total = 1, times = { 0, 0.500001, 0.75 }, matches = false },
		{ gap = 0.75, total = 1, times = { 0, 0.5, 1.000001 }, matches = false },
		{ gap = 0.5, total = 1, times = { 0, 0.25, 0.5 }, matches = true },
	}
do
	it("uses inclusive gap and total windows for " .. table.concat(entry.times, "/"), function()
		expect({ Utils.install(fixture, { Combo = Utils.pattern({ "X", "Q", "Z" }, entry.gap, entry.total) }) }).toEqual({
			true,
		})

		for index: number, id: string in { "X", "Q", "Z" } do
			Utils.press(fixture, entry.times[index], id)
		end

		expect(Utils.ids(fixture)).toEqual(if entry.matches then { "Combo" } else {})
	end)
end

it("expires idle partials and releases their scheduler references without more input", function()
	expect({ Utils.install(fixture, { Combo = Utils.pattern({ "X", "Q" }) }) }).toEqual({ true })
	Utils.press(fixture, 0, "X")
	expect(Utils.pending(fixture) > 0).toBe(true)
	Utils.wake(fixture, 0.500001)
	expect(Utils.pending(fixture)).toBe(0)
	Utils.press(fixture, 0.75, "Q")
	expect(Utils.ids(fixture)).toEqual({})
end)

for _, timerFirst: boolean in { true, false } do
	it("accepts an equality-time final key with timerFirst=" .. tostring(timerFirst), function()
		expect({ Utils.install(fixture, { Combo = Utils.pattern({ "X", "Q" }, 0.5, 0.5) }) }).toEqual({ true })
		Utils.press(fixture, 0, "X")

		if timerFirst then
			Utils.wake(fixture, 0.5)
		end

		Utils.press(fixture, 0.5, "Q")
		Utils.wake(fixture, 0.500001)
		expect(Utils.ids(fixture)).toEqual({ "Combo" })
		expect(Utils.pending(fixture)).toBe(0)
	end)
end

it("uses delayed Tap availability instead of its earlier recognizedAt", function()
	expect({
		fixture.input.owner.SetSource("Gestures", {
			gestures = {
				Q = {
					Tap = { maxDurationSeconds = 0.25 },
					DoubleTapped = {
						maxTapDurationSeconds = 0.25,
						maxGapSeconds = 0.5,
						arbitration = "DeferredTap",
					},
				},
			},
		}),
	}).toEqual({ true })

	expect({ Utils.install(fixture, { Combo = Utils.pattern({ "X", { inputId = "Q", kind = "Tap" } }, 0.25, 0.5) }) }).toEqual({
		true,
	})

	Utils.press(fixture, 0, "X")
	Utils.press(fixture, 0.125, "Q")
	Utils.wake(fixture, 1)
	expect(#fixture.events).toBe(1)
	expect(Utils.ids(fixture)).toEqual({})
end)

it("does not replay intervening keys behind a deferred Tap", function()
	expect({
		fixture.input.owner.SetSource("Gestures", {
			gestures = {
				Q = {
					Tap = { maxDurationSeconds = 0.25 },
					DoubleTapped = {
						maxTapDurationSeconds = 0.25,
						maxGapSeconds = 0.5,
						arbitration = "DeferredTap",
					},
				},
			},
		}),
	}).toEqual({ true })

	expect({ Utils.install(fixture, { Combo = Utils.pattern({ { inputId = "Q", kind = "Tap" }, "Z" }, 1, 2) }) }).toEqual({
		true,
	})

	Utils.press(fixture, 0, "Q")
	Utils.press(fixture, 0.125, "Z")
	Utils.wake(fixture, 0.75)
	expect(Utils.ids(fixture)).toEqual({})
	Utils.press(fixture, 0.875, "Z")
	expect(Utils.ids(fixture)).toEqual({ "Combo" })
end)

it("stamps shared token and occurrence ordinals monotonically under a regressing injected clock", function()
	expect({ Utils.install(fixture, { Combo = Utils.pattern({ "X" }) }) }).toEqual({ true })
	Utils.press(fixture, 1, "X")
	Utils.press(fixture, 0.5, "X")
	expect(#fixture.sequences).toBe(2)
	expect(fixture.sequences[2].triggerTokenOrdinal > fixture.sequences[1].triggerTokenOrdinal).toBe(true)
	expect(fixture.sequences[2].timestamp).toBe(1)

	for index: number = 2, #fixture.envelopes do
		expect(fixture.envelopes[index].occurrenceOrdinal > fixture.envelopes[index - 1].occurrenceOrdinal).toBe(true)
		expect(fixture.envelopes[index].timestamp >= fixture.envelopes[index - 1].timestamp).toBe(true)
	end
end)
