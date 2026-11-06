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

for _, deferred: boolean in { false, true } do
	it("invalidates released partials on dormant context disable with deferred=" .. tostring(deferred), function()
		expect({
			fixture.input.owner.SetSource(
				"Manual",
				if deferred then Utils.deferred() else { sequences = { Combo = Utils.pattern({ "X", "Q", "Z" }) } }
			),
		}).toEqual({ true })

		Utils.play(fixture, { "X", "Q" })
		local primitives: number = #fixture.input.events
		local checked: boolean = false

		fixture.input.owner.ObserveConfigurationCommit(function(change: Types.InputGraphChange): ()
			if change.next.contexts.Signs ~= nil and not change.next.contexts.Signs.enabled then
				expect(Utils.pending(fixture)).toBe(0)
				expect(Utils.ids(fixture)).toEqual({})
				checked = true
			end
		end)

		expect({ fixture.input.owner.SetContextEnabled("Signs", false) }).toEqual({ true })
		expect(checked).toBe(true)
		expect(#fixture.input.events).toBe(primitives)
		expect({ fixture.input.owner.SetContextEnabled("Signs", true) }).toEqual({ true })
		Utils.press(fixture, 0.25, "Z")
		Utils.wake(fixture, 10)
		expect(Utils.ids(fixture)).toEqual({})
	end)
end

it("silently drops active partials on cancellation and suppresses native final end", function()
	expect({ Utils.install(fixture, { Combo = Utils.pattern({ "X", "Q" }) }) }).toEqual({ true })
	Utils.emit(fixture, 0, "X")
	fixture.input.syntheticEnd = true
	expect({ fixture.input.owner.SetContextEnabled("Signs", false) }).toEqual({ true })
	expect(fixture.input.events[2].kind).toBe("Cancelled")
	expect({ fixture.input.owner.SetContextEnabled("Signs", true) }).toEqual({ true })
	Utils.press(fixture, 0.25, "Q")
	expect(Utils.ids(fixture)).toEqual({})
end)

it("preserves unaffected partials across an unrelated context disable", function()
	expect({ Utils.install(fixture, { Combo = Utils.pattern({ "X", "Q" }) }) }).toEqual({ true })
	Utils.press(fixture, 0, "X")
	expect({ fixture.input.owner.SetContextEnabled("Aim", false) }).toEqual({ true })
	Utils.press(fixture, 0.25, "Q")
	expect(Utils.ids(fixture)).toEqual({ "Combo" })
end)

it("preserves native identity, partials and custom state on equivalent source reapplication", function()
	local seen: { boolean } = {}

	local source: Types.InputSourceDefinition = {
		sequences = { Combo = Utils.pattern({ "X", "Q" }) },
		recognizers = {
			Counter = Utils.recognizer(
				function(ctx: Types.RecognizerContext, event: Types.RecognizerEvent): Types.CustomMatch?
					if event.kind == "Pressed" then
						table.insert(seen, ctx:GetState("seen") == true)
						ctx:SetState("seen", true)
					end

					return nil
				end
			),
		},
	}

	expect({ fixture.input.owner.SetSource("Manual", source) }).toEqual({ true })
	local action: InputAction = fixture.input.actions.X
	Utils.press(fixture, 0, "X")
	local pending: number = Utils.pending(fixture)
	local writes: number = #fixture.input.writes
	expect({ fixture.input.owner.SetSource("Manual", source) }).toEqual({ true })
	expect(#fixture.input.writes).toBe(writes)
	expect(fixture.input.actions.X).toBe(action)
	expect(Utils.pending(fixture)).toBe(pending)
	Utils.press(fixture, 0.125, "X")
	Utils.press(fixture, 0.25, "Q")
	expect(seen).toEqual({ false, true })
	expect(Utils.ids(fixture)).toEqual({ "Combo" })
end)

it("resets materially replaced patterns without dropping an unchanged sibling", function()
	expect({
		Utils.install(fixture, { Changed = Utils.pattern({ "X", "Q" }), Continuous = Utils.pattern({ "X", "Z" }) }),
	}).toEqual({ true })

	Utils.press(fixture, 0, "X")

	expect({
		Utils.install(
			fixture,
			{ Changed = Utils.pattern({ "X", "Q" }, 0.25), Continuous = Utils.pattern({ "X", "Z" }) }
		),
	}).toEqual({ true })

	Utils.press(fixture, 0.125, "Q")
	Utils.press(fixture, 0.25, "Z")
	expect(Utils.ids(fixture)).toEqual({ "Continuous" })
end)

it("preserves old partials and deadlines after rejected combined replacement", function()
	expect({ fixture.input.owner.SetSource("Manual", Utils.deferred()) }).toEqual({ true })
	Utils.play(fixture, { "X", "Q" })
	local writes: number = #fixture.input.writes
	local pending: number = Utils.pending(fixture)
	local source: Types.InputSourceDefinition = Utils.deferred()
	assert(source.sequences).Invalid = Utils.pattern({ "Missing" })
	local success: boolean = fixture.input.owner.SetSource("Manual", source)
	expect(success).toBe(false)
	expect(#fixture.input.writes).toBe(writes)
	expect(Utils.pending(fixture)).toBe(pending)
	Utils.wake(fixture, 0.625001)
	expect(Utils.ids(fixture)).toEqual({ "Short" })
end)

for _, selected: boolean in { false, true } do
	it("resets selected or all histories without synthetic lifecycle events selected=" .. tostring(selected), function()
		expect({ Utils.install(fixture, { Signs = Utils.pattern({ "X", "Q" }), Other = Utils.pattern({ "Z", "A" }) }) }).toEqual({
			true,
		})

		Utils.play(fixture, { "X", "Z" })
		local events: number = #fixture.input.events

		expect({ fixture.input.owner.ResetRecognition(if selected then { "X" } else nil, "ActorChanged") }).toEqual({
			true,
		})

		expect(#fixture.input.events).toBe(events)
		Utils.play(fixture, { "Q", "A" }, 0.25)
		expect(Utils.ids(fixture)).toEqual(if selected then { "Other" } else {})
	end)
end

it("prepares a side-effect-free combined reset and retires I2/I3 before Actor publication", function()
	expect({ fixture.input.owner.SetSource("Manual", Utils.deferred()) }).toEqual({ true })

	expect({ fixture.input.owner.SetSource("Gestures", { gestures = { Z = { Held = { afterSeconds = 1 } } } }) }).toEqual({
		true,
	})

	Utils.play(fixture, { "X", "Q" })
	Utils.emit(fixture, 0.25, "Z")
	local pending: number = Utils.pending(fixture)

	local reset: Types.PreparedRecognitionReset?, reason: string? =
		fixture.input.owner.PrepareRecognitionReset(nil, "ActorChanged")

	expect(reason).toBeNil()
	expect(reset ~= nil).toBe(true)
	expect(Utils.pending(fixture)).toBe(pending)
	expect(Utils.ids(fixture)).toEqual({})
	local invalidation: Types.PreparedInputInvalidation? = fixture.input.owner.PrepareEpochInvalidation("ActorChanged")

	expect({
		fixture.input.owner.CommitEpochInvalidation(
			assert(invalidation, "Expected prepared epoch invalidation"),
			function(): ()
				expect({
					fixture.input.owner.CommitPreparedRecognitionReset(
						assert(reset, "Expected prepared recognition reset")
					),
				}).toEqual({ true })

				expect(Utils.pending(fixture)).toBe(0)
				expect(Utils.ids(fixture)).toEqual({})
			end
		),
	}).toEqual({ true })

	Utils.wake(fixture, 10)
	expect(#fixture.events).toBe(0)
	expect(Utils.ids(fixture)).toEqual({})
end)

it("removal and terminal teardown cancel every deadline and reject stale callbacks", function()
	expect({ fixture.input.owner.SetSource("Manual", Utils.deferred()) }).toEqual({ true })
	Utils.play(fixture, { "X", "Q" })
	local callbacks: { () -> () } = {}

	for _, job in fixture.jobs do
		table.insert(callbacks, job.callback)
	end

	expect({ fixture.input.owner.RemoveSource("Manual") }).toEqual({ true })
	expect(Utils.pending(fixture)).toBe(0)
	fixture.input.now = 10

	for _, callback in callbacks do
		callback()
	end

	expect(Utils.ids(fixture)).toEqual({})
	expect(Utils.pending(fixture)).toBe(0)
	fixture.input.owner.Destroy()
	fixture.input.now = 10

	for _, callback in callbacks do
		callback()
	end

	expect(Utils.ids(fixture)).toEqual({})
	expect(fixture.input.connections).toBe(0)
	expect(fixture.input.owner.GetSequence("Short")).toBeNil()
end)

it("preserves custom state when only an unwatched gesture changes on the same input", function()
	local observed: { boolean } = {}

	local definition: Types.RecognizerDefinition = Utils.recognizer(
		function(ctx: Types.RecognizerContext, event: Types.RecognizerEvent): Types.CustomMatch?
			if event.kind == "Pressed" then
				table.insert(observed, ctx:GetState("seen") == true)
				ctx:SetState("seen", true)
			end

			return nil
		end
	)

	definition.gestures = { X = { "Held" } }

	expect({
		fixture.input.owner.SetSource(
			"Gestures",
			{ gestures = { X = { Held = { afterSeconds = 1 }, Tap = { maxDurationSeconds = 0.25 } } } }
		),
	}).toEqual({ true })

	expect({ fixture.input.owner.SetSource("Custom", { recognizers = { State = definition } }) }).toEqual({ true })
	Utils.press(fixture, 0, "X")

	expect({
		fixture.input.owner.SetSource(
			"Gestures",
			{ gestures = { X = { Held = { afterSeconds = 1 }, Tap = { maxDurationSeconds = 0.5 } } } }
		),
	}).toEqual({ true })

	Utils.press(fixture, 0.125, "X")

	expect({
		fixture.input.owner.SetSource(
			"Gestures",
			{ gestures = { X = { Held = { afterSeconds = 2 }, Tap = { maxDurationSeconds = 0.5 } } } }
		),
	}).toEqual({ true })

	Utils.press(fixture, 0.25, "X")
	expect(observed).toEqual({ false, true, false })
end)

it("canonicalizes unordered whitelists before deciding whether a source changed", function()
	expect({
		fixture.input.owner.SetSource("Gestures", {
			gestures = {
				X = {
					Tap = { maxDurationSeconds = 0.25 },
					Held = { afterSeconds = 1 },
					LongHeld = { afterSeconds = 2 },
				},
			},
		}),
	}).toEqual({ true })

	local seen: { boolean } = {}

	local definition: Types.RecognizerDefinition = Utils.recognizer(
		function(ctx: Types.RecognizerContext, event: Types.RecognizerEvent): Types.CustomMatch?
			if event.kind == "Pressed" then
				table.insert(seen, ctx:GetState("seen") == true)
				ctx:SetState("seen", true)
			end

			return nil
		end
	)

	definition.inputs = { "X", "Q" }
	definition.gestures = { X = { "Tap", "Held" } }

	local pattern: Types.SequenceDefinition = Utils.pattern({ "X", "Q" })
	pattern.scope = { "Q", "X" }
	pattern.watchedTokens = { { inputId = "X", kind = "Held" }, { inputId = "X", kind = "LongHeld" } }

	expect({
		fixture.input.owner.SetSource(
			"Manual",
			{ sequences = { Combo = pattern }, recognizers = { State = definition } }
		),
	}).toEqual({ true })

	Utils.press(fixture, 0, "X")
	local previous: Types.RecognizerSnapshot = assert(fixture.input.owner.GetRecognizer("State"), "Expected recognizer")
	local commits: number = 0

	fixture.input.owner.ObserveConfigurationCommit(function()
		commits += 1
	end)

	definition.inputs = { "Q", "X" }
	definition.gestures = { X = { "Held", "Tap" } }
	pattern.scope = { "X", "Q" }

	pattern.watchedTokens =
		{ { inputId = "X", kind = "LongHeld" }, { inputId = "X", kind = "Held" }, { inputId = "X", kind = "Held" } }

	expect({
		fixture.input.owner.SetSource(
			"Manual",
			{ sequences = { Combo = pattern }, recognizers = { State = definition } }
		),
	}).toEqual({ true })

	expect(commits).toBe(0)
	expect(fixture.input.owner.GetRecognizer("State")).toBe(previous)
	Utils.press(fixture, 0.125, "Q")
	expect(seen).toEqual({ false, true })
	expect(Utils.ids(fixture)).toEqual({ "Combo" })
end)
