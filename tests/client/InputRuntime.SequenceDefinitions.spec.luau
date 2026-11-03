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

it("atomically installs native, gesture, custom and sequence definitions without invoking callbacks", function()
	local calls: number = 0

	local source: Types.InputSourceDefinition = {
		contexts = { Extra = { priority = 3, sink = false } },
		inputs = { Confirm = { context = "Extra", type = Enum.InputActionType.Bool, bindings = {} } },
		gestures = { Confirm = { Tap = { maxDurationSeconds = 0.25 } } },
		recognizers = {
			Swipe = {
				inputs = { "Confirm" },
				maxWindowSeconds = 1,
				onEvent = function(): Types.CustomMatch?
					calls += 1

					return nil
				end,
			},
		},
		sequences = {
			Combo = Utils.pattern({
				{ inputId = "Confirm", kind = "Tap" },
				{ recognizerId = "Swipe", kind = "Custom" },
			}),
		},
	}

	expect({ fixture.input.owner.SetSource("Combined", source) }).toEqual({ true })
	expect(calls).toBe(0)
	expect(assert(fixture.input.owner.GetInput("Confirm")).sourceId).toBe("Combined")
	local snapshot: Types.SequenceSnapshot = assert(fixture.input.owner.GetSequence("Combo"))
	expect(snapshot.sourceId).toBe("Combined")
	expect(snapshot.sequenceId).toBe("Combo")
	expect(table.isfrozen(snapshot)).toBe(true)
	expect(table.isfrozen(snapshot.definition)).toBe(true)
	expect(table.isfrozen(snapshot.definition.steps)).toBe(true)
	assert(source.sequences).Combo.steps[1] = "Z"
	expect(snapshot.definition.steps[1]).toEqual({ inputId = "Confirm", kind = "Tap" })
	expect(assert(fixture.input.owner.GetRecognizer("Swipe")).faulted).toBe(false)
end)

for _, entry in
	{
		{ steps = { "Missing" }, reason = "UnknownSequenceInput" },
		{ steps = { "Aim" }, reason = "SequenceRequiresBool" },
		{ steps = { { inputId = "X", kind = "Tap" } }, reason = "UnknownSequenceGesture" },
		{ steps = { { recognizerId = "Missing", kind = "Custom" } }, reason = "UnknownSequenceRecognizer" },
	}
do
	it("rejects " .. entry.reason .. " before applying an accompanying keybind", function()
		local writes: number = #fixture.input.writes

		local source: any = {
			bindingOverrides = { X = { Keyboard = { keyCode = Enum.KeyCode.E } } },
			sequences = { Combo = Utils.pattern(entry.steps :: any) },
		}

		expect({ fixture.input.owner.SetSource("Invalid", source) }).toEqual({ false, entry.reason })
		expect(#fixture.input.writes).toBe(writes)
		expect(fixture.input.owner.GetSequence("Combo")).toBeNil()
		expect(fixture.input.bindings["X:Keyboard"].KeyCode).toBe(Enum.KeyCode.Space)
	end)
end

it("rejects duplicate canonical sequence IDs regardless of source priority", function()
	expect({ Utils.install(fixture, { Combo = Utils.pattern({ "X" }) }, "First") }).toEqual({ true })

	expect({
		fixture.input.owner.SetSource("Second", { priority = 999, sequences = { Combo = Utils.pattern({ "X" }) } }),
	}).toEqual({ false, "DuplicateSequenceOwner" })

	expect(assert(fixture.input.owner.GetSequence("Combo")).sourceId).toBe("First")
end)

it("permits identical signatures owned by independent IDs in canonical result order", function()
	expect({ Utils.install(fixture, { Zebra = Utils.pattern({ "X", "Q" }) }, "First") }).toEqual({ true })
	expect({ Utils.install(fixture, { Alpha = Utils.pattern({ "X", "Q" }) }, "Second") }).toEqual({ true })
	Utils.play(fixture, { "X", "Q" })
	expect(Utils.ids(fixture)).toEqual({ "Alpha", "Zebra" })
	expect(fixture.sequences[1].sourceId).toBe("Second")
	expect(fixture.sequences[2].sourceId).toBe("First")
end)

it("keeps sequence, input and custom identity namespaces separate", function()
	expect({
		fixture.input.owner.SetSource("Names", {
			sequences = { X = Utils.pattern({ "X" }) },
			recognizers = { X = Utils.recognizer(function(): Types.CustomMatch?
				return {}
			end) },
		}),
	}).toEqual({ true })

	Utils.press(fixture, 0, "X")
	expect(fixture.sequences[1].sequenceId).toBe("X")
	expect(fixture.recognizers[1].recognizerId).toBe("X")
	expect(assert(fixture.input.owner.GetInput("X")).sourceId).toBe("Core")
end)

it("rejects foreign dependencies being removed or changed without touching installed history", function()
	expect({ fixture.input.owner.SetSource("Gestures", { gestures = { X = { Tap = { maxDurationSeconds = 0.25 } } } }) }).toEqual({
		true,
	})

	expect({
		fixture.input.owner.SetSource(
			"Custom",
			{ recognizers = { Swipe = Utils.recognizer(function(): Types.CustomMatch?
				return {}
			end) } }
		),
	}).toEqual({ true })

	expect({
		Utils.install(fixture, {
			TapCombo = Utils.pattern({ { inputId = "X", kind = "Tap" }, "Q" }),
			SwipeCombo = Utils.pattern({ { recognizerId = "Swipe", kind = "Custom" }, "Q" }),
		}),
	}).toEqual({ true })

	expect({ fixture.input.owner.RemoveSource("Gestures") }).toEqual({ false, "UnknownSequenceGesture" })
	expect({ fixture.input.owner.RemoveSource("Custom") }).toEqual({ false, "UnknownSequenceRecognizer" })
	expect({ fixture.input.owner.RemoveSource("Core") }).toEqual({ false, "UnknownGestureInput" })
	expect({ fixture.input.owner.GetSequence("TapCombo") ~= nil }).toEqual({ true })
	expect({ fixture.input.owner.RemoveSource("Manual") }).toEqual({ true })
	expect({ fixture.input.owner.RemoveSource("Gestures") }).toEqual({ true })
	expect({ fixture.input.owner.RemoveSource("Custom") }).toEqual({ true })
end)

it("prepares prospective recognition without publishing it and commits the same validated graph", function()
	local writes: number = #fixture.input.writes

	local plan: Types.PreparedInputUpdate?, reason: string? =
		fixture.input.owner.PrepareSource("Manual", { sequences = { Combo = Utils.pattern({ "X", "Q" }) } })

	expect(reason).toBeNil()
	expect(plan ~= nil).toBe(true)
	expect(fixture.input.owner.GetSequence("Combo")).toBeNil()
	expect(#fixture.input.writes).toBe(writes)
	expect({ fixture.input.owner.CommitPrepared(assert(plan, "Expected prepared source plan")) }).toEqual({ true })
	expect(assert(fixture.input.owner.GetSequence("Combo")).sourceId).toBe("Manual")
end)
