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

local invalidCatalogs: { { source: any, reason: string } } = {
	{ source = { sequences = false }, reason = "InvalidSequence" },
	{ source = { sequences = { [""] = Utils.pattern({ "X" }) } }, reason = "InvalidSequence" },
	{ source = { recognizers = false }, reason = "InvalidRecognizer" },
	{
		source = {
			recognizers = { [""] = Utils.recognizer(function(): Types.CustomMatch?
				return nil
			end) },
		},
		reason = "InvalidRecognizer",
	},
	{
		source = {
			recognizers = {
				Bad = {
					inputs = { "X" },
					maxWindowSeconds = 1,
					onEvent = function(): Types.CustomMatch?
						return nil
					end,
					gestures = false,
				},
			},
		},
		reason = "InvalidRecognizer",
	},
	{
		source = {
			recognizers = {
				Bad = {
					inputs = { "X" },
					maxWindowSeconds = 1,
					onEvent = function(): Types.CustomMatch?
						return nil
					end,
					gestures = { X = { "Missing" } },
				},
			},
		},
		reason = "InvalidRecognizer",
	},
	{
		source = {
			recognizers = {
				Bad = {
					inputs = { "X" },
					maxWindowSeconds = 1,
					onEvent = function(): Types.CustomMatch?
						return nil
					end,
					gestures = { X = { "Tap", "Tap" } },
				},
			},
		},
		reason = "InvalidRecognizer",
	},
	{
		source = {
			recognizers = {
				Bad = {
					inputs = { "X" },
					maxWindowSeconds = 1,
					onEvent = function(): Types.CustomMatch?
						return nil
					end,
					gestures = { X = { "Tap" } },
				},
			},
		},
		reason = "UnknownRecognizerGesture",
	},
	{ source = { sequenceGroups = false }, reason = "InvalidSequenceGroup" },
	{
		source = {
			sequenceGroups = {
				[""] = { policy = "DeferredPrefix", maxGapSeconds = 1, maxTotalSeconds = 2, scope = { "X" } },
			},
		},
		reason = "InvalidSequenceGroup",
	},
	{
		source = {
			sequenceGroups = {
				Bad = { policy = "DeferredPrefix", maxGapSeconds = 0, maxTotalSeconds = 2, scope = { "X" } },
			},
		},
		reason = "InvalidSequenceGroup",
	},
	{
		source = {
			sequenceGroups = {
				Bad = { policy = "DeferredPrefix", maxGapSeconds = 1, maxTotalSeconds = 0, scope = { "X" } },
			},
		},
		reason = "InvalidSequenceGroup",
	},
	{
		source = {
			sequenceGroups = {
				Bad = { policy = "DeferredPrefix", maxGapSeconds = 1, maxTotalSeconds = 2, scope = { "X", "X" } },
			},
		},
		reason = "InvalidSequenceGroup",
	},
	{
		source = {
			sequenceGroups = {
				Bad = {
					policy = "DeferredPrefix",
					maxGapSeconds = 1,
					maxTotalSeconds = 2,
					scope = { "X" },
					watchedTokens = { "X" },
				},
			},
		},
		reason = "InvalidSequenceGroup",
	},
}

for _, entry in invalidCatalogs do
	it("rejects malformed recognition catalogs with " .. entry.reason .. " before any native writes", function()
		local writes: number = #fixture.input.writes
		expect({ fixture.input.owner.SetSource("Invalid", entry.source) }).toEqual({ false, entry.reason })
		expect(#fixture.input.writes).toBe(writes)
	end)
end

it("rejects over-budget single-source catalogs before native allocation", function()
	local sequences: { [string]: Types.SequenceDefinition } = {}

	for index: number = 1, Constants.MAX_SEQUENCES + 1 do
		sequences[tostring(index)] = Utils.pattern({ "X" })
	end

	expect({ Utils.install(fixture, sequences) }).toEqual({ false, "InputSequenceLimitExceeded" })
	local recognizers: { [string]: Types.RecognizerDefinition } = {}

	for index: number = 1, Constants.MAX_RECOGNIZERS + 1 do
		recognizers[tostring(index)] = Utils.recognizer(function()
			return nil
		end)
	end

	expect({ fixture.input.owner.SetSource("Invalid", { recognizers = recognizers }) }).toEqual({
		false,
		"InputRecognizerLimitExceeded",
	})
end)

it("lets explicitly watched I2 tokens invalidate a pattern while unlisted gestures remain independent", function()
	expect({ fixture.input.owner.SetSource("Gestures", { gestures = { Q = { Tap = { maxDurationSeconds = 0.25 } } } }) }).toEqual({
		true,
	})

	local pattern: Types.SequenceDefinition = Utils.pattern({ "X", "Z" })
	pattern.watchedTokens = { { inputId = "Q", kind = "Tap" } }
	expect({ Utils.install(fixture, { Combo = pattern }) }).toEqual({ true })
	Utils.play(fixture, { "X", "Q", "Z" })
	expect(Utils.ids(fixture)).toEqual({})
	Utils.play(fixture, { "X", "Z" }, 1)
	expect(Utils.ids(fixture)).toEqual({ "Combo" })
end)

it("rejects string watched-token shorthand while accepting an empty explicit alphabet", function()
	local pattern: any = Utils.pattern({ "X" })
	pattern.watchedTokens = { "X" }
	expect({ Utils.install(fixture, { Combo = pattern }) }).toEqual({ false, "InvalidSequence" })
	pattern.watchedTokens = {}
	expect({ Utils.install(fixture, { Combo = pattern }) }).toEqual({ true })
end)
