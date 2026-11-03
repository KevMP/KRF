--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local Types = require(ReplicatedStorage.Packages.KRF.client.Input.types)
local Constants = require(ReplicatedStorage.Packages.KRF.client.Input.utils.InputConstants)
local Utils = require(script.Parent.Utils.SequenceTestUtils)
local fixture: Utils.Fixture

beforeEach(function()
	fixture = Utils.new()
end)

afterEach(function()
	Utils.destroy(fixture)
end)

it("copies recognizer declarations while retaining callback identity", function()
	local callback = function(): Types.CustomMatch?
		return nil
	end

	local definition: Types.RecognizerDefinition = Utils.recognizer(callback)
	expect({ fixture.input.owner.SetSource("Custom", { recognizers = { Swipe = definition } }) }).toEqual({ true })
	local snapshot: Types.RecognizerSnapshot = assert(fixture.input.owner.GetRecognizer("Swipe"))
	expect(snapshot.recognizerId).toBe("Swipe")
	expect(snapshot.sourceId).toBe("Custom")
	expect(snapshot.definition.onEvent).toBe(callback)
	expect(table.isfrozen(snapshot)).toBe(true)
	expect(table.isfrozen(snapshot.definition)).toBe(true)
	expect(table.isfrozen(snapshot.definition.inputs)).toBe(true)
	definition.inputs[1] = "Q"
	expect(snapshot.definition.inputs).toEqual({ "X" })
end)

it("rejects duplicate custom IDs and permits distinct recognizers with the same watched inputs", function()
	local definition: Types.RecognizerDefinition = Utils.recognizer(function(): Types.CustomMatch?
		return nil
	end)

	expect({ fixture.input.owner.SetSource("First", { recognizers = { Swipe = definition } }) }).toEqual({ true })

	expect({ fixture.input.owner.SetSource("Second", { recognizers = { Swipe = definition } }) }).toEqual({
		false,
		"DuplicateRecognizerOwner",
	})

	expect({ fixture.input.owner.SetSource("Second", { recognizers = { Other = definition } }) }).toEqual({ true })
end)

for _, definition: any in
	{
		{},
		{ inputs = {}, maxWindowSeconds = 1, onEvent = function() end },
		{ inputs = { "Missing" }, maxWindowSeconds = 1, onEvent = function() end },
		{ inputs = { "X", "X" }, maxWindowSeconds = 1, onEvent = function() end },
		{ inputs = { "X" }, maxWindowSeconds = 1, onEvent = true },
		{ inputs = { "X" }, maxWindowSeconds = 1, onEvent = function() end, onDeadline = 3 },
		{ inputs = { "X" }, maxWindowSeconds = 1, onEvent = function() end, gestures = { Q = { "Tap" } } },
		{ inputs = { "X" }, maxWindowSeconds = 1, onEvent = function() end, recognizers = { "Other" } },
		{ inputs = { "X" }, maxWindowSeconds = 1, onEvent = function() end, sequences = { "Combo" } },
		setmetatable({ inputs = { "X" }, maxWindowSeconds = 1, onEvent = function() end }, {}),
	}
do
	it("rejects malformed custom declarations without changing native objects", function()
		local writes: number = #fixture.input.writes

		local success: boolean, reason: string? =
			fixture.input.owner.SetSource("Custom", { recognizers = { Swipe = definition } })

		expect(success).toBe(false)
		expect(type(reason)).toBe("string")
		expect(#fixture.input.writes).toBe(writes)
		expect(fixture.input.owner.GetRecognizer("Swipe")).toBeNil()
	end)
end

for _, window: any in { 0, -1, math.huge, 0 / 0, "1", Constants.MAX_RECOGNITION_WINDOW_SECONDS + 1 } do
	it("rejects invalid fixed custom window " .. tostring(window), function()
		local definition: any = Utils.recognizer(function(): Types.CustomMatch?
			return nil
		end)

		definition.maxWindowSeconds = window

		expect({ fixture.input.owner.SetSource("Custom", { recognizers = { Swipe = definition } }) }).toEqual({
			false,
			"InvalidRecognizer",
		})
	end)
end

it("delivers only declared primitive inputs and declared I2 gestures, never I3 outputs", function()
	local seen: { string } = {}

	expect({
		fixture.input.owner.SetSource("Gestures", {
			gestures = {
				X = {
					Tap = { maxDurationSeconds = 0.25 },
					DoubleTapped = { maxTapDurationSeconds = 0.25, maxGapSeconds = 0.5 },
				},
			},
		}),
	}).toEqual({ true })

	local definition: Types.RecognizerDefinition = Utils.recognizer(
		function(_ctx: Types.RecognizerContext, event: Types.RecognizerEvent): Types.CustomMatch?
			table.insert(seen, event.inputId .. ":" .. (if event.kind == "Gesture" then event.gesture else event.kind))

			return {}
		end
	)

	definition.gestures = { X = { "Tap" } }
	expect({ fixture.input.owner.SetSource("Custom", { recognizers = { Watcher = definition } }) }).toEqual({ true })

	expect({ Utils.install(fixture, { Combo = Utils.pattern({ { recognizerId = "Watcher", kind = "Custom" } }) }) }).toEqual({
		true,
	})

	Utils.play(fixture, { "X", "Attack", "Q", "X" })
	expect(seen).toEqual({ "X:Pressed", "X:Released", "X:Tap", "X:Pressed", "X:Released", "X:Tap" })
	expect(#fixture.recognizers).toBe(4)
end)

for _, size: number in { Constants.MAX_RECOGNIZERS, Constants.MAX_RECOGNIZERS + 1 } do
	it("enforces the composed recognizer bound at " .. tostring(size), function()
		local definitions: { [string]: Types.RecognizerDefinition } = {}

		for index: number = 1, size - 1 do
			definitions[tostring(index)] = Utils.recognizer(function(): Types.CustomMatch?
				return nil
			end)
		end

		expect({ fixture.input.owner.SetSource("Catalog", { recognizers = definitions }) }).toEqual({ true })

		expect({
			fixture.input.owner.SetSource(
				"Last",
				{ recognizers = { Last = Utils.recognizer(function(): Types.CustomMatch?
					return nil
				end) } }
			),
		}).toEqual(if size <= Constants.MAX_RECOGNIZERS then { true } else { false, "InputRecognizerLimitExceeded" })
	end)
end

it("delivers declared cancellation observations without emitting a custom completion", function()
	local observed: { string } = {}

	expect({
		fixture.input.owner.SetSource("Custom", {
			recognizers = {
				Cancel = Utils.recognizer(
					function(_ctx: Types.RecognizerContext, event: Types.RecognizerEvent): Types.CustomMatch?
						table.insert(observed, event.kind)

						return if event.kind == "Cancelled" then {} else nil
					end
				),
			},
		}),
	}).toEqual({ true })

	Utils.emit(fixture, 0, "X")
	expect({ fixture.input.owner.SetContextEnabled("Signs", false) }).toEqual({ true })
	expect(observed).toEqual({ "Pressed", "Cancelled" })
	expect(#fixture.recognizers).toBe(0)
	expect(Utils.pending(fixture)).toBe(0)
end)
