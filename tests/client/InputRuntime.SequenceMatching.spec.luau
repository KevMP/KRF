--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local Types = require(ReplicatedStorage.Packages.KRF.client.Input.types)
local Utils = require(script.Parent.Utils.SequenceTestUtils)
local fixture: Utils.Fixture

beforeEach(function()
	fixture = Utils.new()
end)

afterEach(function()
	Utils.destroy(fixture)
end)

it("matches released hand signs immediately without delaying primitive notifications", function()
	expect({ Utils.install(fixture, { Combo = Utils.pattern({ "X", "Q", "Z" }) }) }).toEqual({ true })
	Utils.play(fixture, { "X", "Q" })
	expect(Utils.ids(fixture)).toEqual({})
	expect(#fixture.input.events).toBe(4)
	Utils.emit(fixture, 0.25, "Z")
	expect(Utils.ids(fixture)).toEqual({ "Combo" })
	local event: Types.SequenceMatchEvent = fixture.sequences[1]
	expect(event.sourceId).toBe("Manual")
	expect(event.matchedStepCount).toBe(3)
	expect(event.recognizedAt).toBe(0.25)
	expect(event.timestamp).toBe(0.25)
	expect(table.isfrozen(event)).toBe(true)

	expect(assert(table.find(fixture.trace, "Envelope:Root")) < assert(table.find(fixture.trace, "Input:Pressed"))).toBe(
		true
	)
end)

for _, entry in
	{
		{ steps = { "X", "X", "Q" }, played = { "X", "X", "X", "Q" }, count = 1 },
		{ steps = { "X", "Q", "X" }, played = { "X", "Q", "X", "Q", "X" }, count = 2 },
		{ steps = { "X", "Q" }, played = { "X", "X", "Q" }, count = 1 },
		{ steps = { "X" }, played = { "X", "X", "X" }, count = 3 },
	}
do
	it("retains suffix starts for " .. table.concat(entry.played, "/"), function()
		expect({ Utils.install(fixture, { Combo = Utils.pattern(entry.steps :: { Types.SequenceStep }) }) }).toEqual({
			true,
		})

		Utils.play(fixture, entry.played)
		expect(#fixture.sequences).toBe(entry.count)

		for _, event: Types.SequenceMatchEvent in fixture.sequences do
			expect(event.sequenceId).toBe("Combo")
		end
	end)
end

it("ignores unwatched input and gestures but retries a watched wrong sign", function()
	expect({ fixture.input.owner.SetSource("Gestures", { gestures = { Q = { Tap = { maxDurationSeconds = 0.25 } } } }) }).toEqual({
		true,
	})

	local pattern: Types.SequenceDefinition = Utils.pattern({ "X", "Q", "Z" })
	pattern.scope = { "X", "Q", "Z", "C" }
	expect({ Utils.install(fixture, { Combo = pattern }) }).toEqual({ true })
	Utils.play(fixture, { "X", "Attack", "Q", "Z" }, 0, 0.0625)
	expect(Utils.ids(fixture)).toEqual({ "Combo" })
	Utils.play(fixture, { "X", "Q", "C", "Z" }, 0.5, 0.0625)
	expect(Utils.ids(fixture)).toEqual({ "Combo" })
	Utils.play(fixture, { "X", "Q", "X", "Q", "Z" }, 1, 0.0625)
	expect(Utils.ids(fixture)).toEqual({ "Combo", "Combo" })
end)

it("emits shorter, identical and suffix patterns independently in canonical order", function()
	expect({
		Utils.install(fixture, {
			Short = Utils.pattern({ "X", "Q" }),
			Long = Utils.pattern({ "X", "Q", "Z" }),
			Duplicate = Utils.pattern({ "X", "Q", "Z" }),
			Suffix = Utils.pattern({ "Q", "Z" }),
		}),
	}).toEqual({ true })

	Utils.play(fixture, { "X", "Q" })
	expect(Utils.ids(fixture)).toEqual({ "Short" })
	Utils.press(fixture, 0.25, "Z")
	expect(Utils.ids(fixture)).toEqual({ "Short", "Duplicate", "Long", "Suffix" })
end)

it("uses different scopes and timing for identical signatures without merging owners", function()
	local narrow: Types.SequenceDefinition = Utils.pattern({ "X", "Q" }, 0.125)
	local wide: Types.SequenceDefinition = Utils.pattern({ "X", "Q" }, 0.5)

	narrow.scope = { "X", "Q", "C" }
	expect({ Utils.install(fixture, { Narrow = narrow, Wide = wide }) }).toEqual({ true })
	Utils.play(fixture, { "X", "C", "Q" }, 0, 0.0625)
	expect(Utils.ids(fixture)).toEqual({ "Wide" })
	Utils.press(fixture, 1, "X")
	Utils.press(fixture, 1.25, "Q")
	expect(Utils.ids(fixture)).toEqual({ "Wide", "Wide" })
end)

it("does not consume Pressed plus DoubleTapped as two steps from one physical root", function()
	expect({
		fixture.input.owner.SetSource(
			"Gestures",
			{ gestures = { Q = { DoubleTapped = { maxTapDurationSeconds = 0.25, maxGapSeconds = 0.5 } } } }
		),
	}).toEqual({ true })

	Utils.press(fixture, 0, "Q")

	expect({ Utils.install(fixture, { Combo = Utils.pattern({ "Q", { inputId = "Q", kind = "DoubleTapped" } }) }) }).toEqual({
		true,
	})

	Utils.emit(fixture, 0.125, "Q")
	expect(#fixture.events).toBe(1)
	expect(fixture.events[1].gesture).toBe("DoubleTapped")
	expect(Utils.ids(fixture)).toEqual({})
	Utils.emit(fixture, 0.1875, "Q", "Released")
	Utils.emit(fixture, 0.25, "Q")
	expect(Utils.ids(fixture)).toEqual({})
end)

it("does not complete Pressed to custom using two alternatives from a single press", function()
	expect({
		fixture.input.owner.SetSource("Custom", {
			recognizers = {
				Sign = Utils.recognizer(
					function(_ctx: Types.RecognizerContext, event: Types.RecognizerEvent): Types.CustomMatch?
						return if event.kind == "Pressed" then {} else nil
					end
				),
			},
		}),
	}).toEqual({ true })

	expect({ Utils.install(fixture, { Combo = Utils.pattern({ "X", { recognizerId = "Sign", kind = "Custom" } }) }) }).toEqual({
		true,
	})

	Utils.press(fixture, 0, "X")
	expect(Utils.ids(fixture)).toEqual({})
	Utils.press(fixture, 0.125, "X")
	expect(Utils.ids(fixture)).toEqual({ "Combo" })
end)

it("keeps a lineage awaiting a gesture when the same root also supplies a watched Pressed alternative", function()
	expect({
		fixture.input.owner.SetSource(
			"Gestures",
			{ gestures = { Q = { DoubleTapped = { maxTapDurationSeconds = 0.25, maxGapSeconds = 0.5 } } } }
		),
	}).toEqual({ true })

	local pattern: Types.SequenceDefinition = Utils.pattern({ "X", { inputId = "Q", kind = "DoubleTapped" } })
	pattern.scope = { "X", "Q" }
	expect({ Utils.install(fixture, { Combo = pattern }) }).toEqual({ true })
	Utils.press(fixture, 0, "Q")
	Utils.press(fixture, 0.125, "X")
	Utils.emit(fixture, 0.25, "Q")
	expect(Utils.ids(fixture)).toEqual({ "Combo" })
end)
