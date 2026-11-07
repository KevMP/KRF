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

it("holds the longest completed prefix until the group's terminal continuation", function()
	expect({ fixture.input.owner.SetSource("Manual", Utils.deferred()) }).toEqual({ true })
	Utils.play(fixture, { "X", "Q" })
	expect(Utils.ids(fixture)).toEqual({})
	Utils.press(fixture, 0.25, "Z")
	expect(Utils.ids(fixture)).toEqual({})
	Utils.press(fixture, 0.375, "A")
	expect(Utils.ids(fixture)).toEqual({ "Longest" })
	Utils.wake(fixture, 10)
	expect(Utils.ids(fixture)).toEqual({ "Longest" })
	expect(Utils.pending(fixture)).toBe(0)
end)

it("flushes a mismatched pending prefix in a separate earlier envelope before the wrong key", function()
	expect({ fixture.input.owner.SetSource("Manual", Utils.deferred()) }).toEqual({ true })
	Utils.play(fixture, { "X", "Q" })
	local count: number = #fixture.envelopes
	Utils.emit(fixture, 0.25, "C")
	expect(Utils.ids(fixture)).toEqual({ "Short" })
	expect(#fixture.envelopes).toBe(count + 2)
	local deferred: Types.InputCandidateEnvelope = fixture.envelopes[count + 1]
	local root: Types.InputCandidateEnvelope = fixture.envelopes[count + 2]
	expect(deferred.kind).toBe("Deferred")
	expect(root.kind).toBe("Root")
	assert(root.kind == "Root", "Expected mismatch root envelope")
	expect(root.rootInputId).toBe("C")
	expect(deferred.occurrenceOrdinal < root.occurrenceOrdinal).toBe(true)
	expect(#deferred.candidates).toBe(1)
	local candidate: Types.RecognitionCandidate = deferred.candidates[1]
	assert(candidate.kind == "Sequence", "Expected sequence lane")
	expect(candidate.sequenceId).toBe("Short")
	expect(candidate.immediate).toBe(false)
	expect(candidate.holdOwner).toBeNil()

	expect(root.candidates).toEqual({
		{
			kind = "Input",
			inputId = "C",
			gesture = "Pressed",
			routeEligible = true,
			pressEpochId = root.rootInputEpochId,
			pressEpochGeneration = root.rootInputEpochGeneration,
			recognitionOrdinal = root.candidates[1].recognitionOrdinal,
		},
	})

	expect(fixture.sequences[1].recognizedAt).toBe(0.125)
	expect(fixture.sequences[1].timestamp).toBe(0.25)
end)

for _, timerFirst: boolean in { true, false } do
	it("lets an inclusive continuation win with timerFirst=" .. tostring(timerFirst), function()
		expect({ fixture.input.owner.SetSource("Manual", Utils.deferred()) }).toEqual({ true })
		Utils.play(fixture, { "X", "Q" })

		if timerFirst then
			Utils.wake(fixture, 0.625)
		end

		Utils.press(fixture, 0.625, "Z")
		expect(Utils.ids(fixture)).toEqual({})
		Utils.wake(fixture, 1.125001)
		expect(Utils.ids(fixture)).toEqual({ "Long" })
		Utils.wake(fixture, 10)
		expect(Utils.ids(fixture)).toEqual({ "Long" })
	end)
end

it("expires an idle pending completion once and never exceeds its fixed total horizon", function()
	local source: Types.InputSourceDefinition = Utils.deferred()
	assert(source.sequenceGroups).Signs.maxTotalSeconds = 0.25
	expect({ fixture.input.owner.SetSource("Manual", source) }).toEqual({ true })
	Utils.play(fixture, { "X", "Q", "Z" }, 0, 0.125)
	expect(Utils.ids(fixture)).toEqual({})
	Utils.wake(fixture, 0.250001)
	expect(Utils.ids(fixture)).toEqual({ "Long" })
	expect(fixture.sequences[1].recognizedAt).toBe(0.25)
	Utils.wake(fixture, 10)
	expect(#fixture.sequences).toBe(1)
	expect(Utils.pending(fixture)).toBe(0)
end)

it("keeps overlapping match-start lineages pending independently", function()
	local source: Types.InputSourceDefinition = {
		sequenceGroups = {
			Repeated = { policy = "DeferredPrefix", maxGapSeconds = 0.5, maxTotalSeconds = 2, scope = { "X", "Q" } },
		},
		sequences = {
			Short = { steps = { "X" }, exclusiveGroup = "Repeated" },
			Long = { steps = { "X", "X", "Q" }, exclusiveGroup = "Repeated" },
		},
	}

	expect({ fixture.input.owner.SetSource("Manual", source) }).toEqual({ true })
	Utils.play(fixture, { "X", "X", "Q" })
	expect(Utils.ids(fixture)).toEqual({ "Short", "Long" })
	-- First lineage completes Long; second lineage's X completes Short on mismatch.
	local counts: { [string]: number } = {}

	for _, event: Types.SequenceMatchEvent in fixture.sequences do
		counts[event.sequenceId] = (counts[event.sequenceId] or 0) + 1
	end

	expect(counts).toEqual({ Short = 1, Long = 1 })
	Utils.wake(fixture, 10)
	expect(#fixture.sequences).toBe(2)
end)

it("does not let a foreign source defer an immediate shorter pattern", function()
	expect({ Utils.install(fixture, { Independent = Utils.pattern({ "X", "Q" }) }, "Other") }).toEqual({ true })
	expect({ fixture.input.owner.SetSource("Manual", Utils.deferred()) }).toEqual({ true })
	Utils.play(fixture, { "X", "Q" })
	expect(Utils.ids(fixture)).toEqual({ "Independent" })
	Utils.press(fixture, 0.25, "Attack")
	expect(Utils.ids(fixture)).toEqual({ "Independent" })
	Utils.wake(fixture, 0.625001)
	expect(Utils.ids(fixture)).toEqual({ "Independent", "Short" })
end)

it("retries a mismatch token as the start of a new lineage after flushing", function()
	expect({ fixture.input.owner.SetSource("Manual", Utils.deferred()) }).toEqual({ true })
	Utils.play(fixture, { "X", "Q", "X", "Q", "Z", "A" })
	expect(Utils.ids(fixture)).toEqual({ "Short", "Longest" })
end)

for _, mode: string in
	{ "UnknownGroup", "NoPrefix", "Disconnected", "MemberTiming", "MemberScope", "ForeignMembership", "UnknownPolicy" }
do
	it("rejects invalid DeferredPrefix configuration " .. mode .. " atomically", function()
		local source: any = Utils.deferred()

		if mode == "UnknownGroup" then
			source.sequences.Short.exclusiveGroup = "Missing"
		elseif mode == "NoPrefix" then
			source.sequences = { Short = { steps = { "X", "Q" }, exclusiveGroup = "Signs" } }
		elseif mode == "Disconnected" then
			source.sequences.Disconnected = { steps = { "A", "C" }, exclusiveGroup = "Signs" }
		elseif mode == "MemberTiming" then
			source.sequences.Short.maxGapSeconds = 1
		elseif mode == "MemberScope" then
			source.sequences.Short.scope = { "X", "Q" }
		elseif mode == "UnknownPolicy" then
			source.sequenceGroups.Signs.policy = "Independent"
		else
			expect({ fixture.input.owner.SetSource("Other", source) }).toEqual({ true })
			source = { sequences = { Foreign = { steps = { "X", "Q" }, exclusiveGroup = "Signs" } } }
		end

		local writes: number = #fixture.input.writes
		expect({ fixture.input.owner.SetSource("Invalid", source) }).toEqual({ false, "InvalidSequenceGroup" })
		expect(#fixture.input.writes).toBe(writes)
		expect(fixture.input.owner.GetSequence("Foreign")).toBeNil()
	end)
end

it("allows two sources to use the same source-local group name", function()
	expect({ fixture.input.owner.SetSource("Manual", Utils.deferred()) }).toEqual({ true })

	expect({
		fixture.input.owner.SetSource("Other", {
			sequenceGroups = {
				Signs = {
					policy = "DeferredPrefix",
					maxGapSeconds = 0.25,
					maxTotalSeconds = 1,
					scope = { "X", "Q", "Z" },
				},
			},
			sequences = {
				OtherShort = { steps = { "Q" }, exclusiveGroup = "Signs" },
				OtherLong = { steps = { "Q", "Z" }, exclusiveGroup = "Signs" },
			},
		}),
	}).toEqual({ true })

	Utils.press(fixture, 0, "Q")
	Utils.wake(fixture, 0.250001)
	expect(Utils.ids(fixture)).toEqual({ "OtherShort" })
end)

it("emits both overlapping pending completions of the same ID in distinct deferred occurrences", function()
	expect({
		fixture.input.owner.SetSource("Manual", {
			sequenceGroups = {
				Repeated = { policy = "DeferredPrefix", maxGapSeconds = 0.5, maxTotalSeconds = 2, scope = { "X", "Q" } },
			},
			sequences = {
				Short = { steps = { "X" }, exclusiveGroup = "Repeated" },
				Long = { steps = { "X", "X", "Q" }, exclusiveGroup = "Repeated" },
			},
		}),
	}).toEqual({ true })

	Utils.play(fixture, { "X", "X" })
	local count: number = #fixture.envelopes
	Utils.wake(fixture, 0.625001)
	expect(Utils.ids(fixture)).toEqual({ "Short", "Short" })
	expect(fixture.sequences[1].recognizedAt).toBe(0)
	expect(fixture.sequences[2].recognizedAt).toBe(0.125)
	expect(#fixture.envelopes).toBe(count + 2)
	expect(fixture.envelopes[count + 1].kind).toBe("Deferred")
	expect(fixture.envelopes[count + 2].kind).toBe("Deferred")
	expect(Utils.pending(fixture)).toBe(0)
end)

it("reschedules an early prefix wake without completing before its inclusive deadline", function()
	expect({ fixture.input.owner.SetSource("Manual", Utils.deferred()) }).toEqual({ true })
	Utils.play(fixture, { "X", "Q" })

	local job = fixture.jobs[#fixture.jobs]
	job.fired = true
	fixture.input.now = 0.25
	job.callback()
	expect(Utils.ids(fixture)).toEqual({})
	expect(Utils.pending(fixture)).toBe(1)
	Utils.wake(fixture, 0.625001)
	expect(Utils.ids(fixture)).toEqual({ "Short" })
end)

it("emits identical deferred signatures under separate canonical IDs in one causal envelope", function()
	local source: Types.InputSourceDefinition = Utils.deferred()
	assert(source.sequences, "Expected sequence declarations").Twin = { steps = { "X", "Q" }, exclusiveGroup = "Signs" }
	expect({ fixture.input.owner.SetSource("Manual", source) }).toEqual({ true })
	Utils.play(fixture, { "X", "Q" })
	local count: number = #fixture.envelopes
	Utils.wake(fixture, 0.625001)
	expect(Utils.ids(fixture)).toEqual({ "Short", "Twin" })
	expect(#fixture.envelopes).toBe(count + 1)
	expect(#fixture.envelopes[count + 1].candidates).toBe(2)
end)

it("halts deferred batches if the owner is destroyed while the first completion is observed", function()
	expect({
		fixture.input.owner.SetSource("Manual", {
			sequenceGroups = {
				Repeated = { policy = "DeferredPrefix", maxGapSeconds = 0.5, maxTotalSeconds = 2, scope = { "X", "Q" } },
			},
			sequences = {
				Short = { steps = { "X" }, exclusiveGroup = "Repeated" },
				Long = { steps = { "X", "X", "Q" }, exclusiveGroup = "Repeated" },
			},
		}),
	}).toEqual({ true })

	Utils.play(fixture, { "X", "X" })
	local count: number = #fixture.envelopes

	fixture.input.owner.ObserveCandidateEnvelope(function(envelope: Types.InputCandidateEnvelope): ()
		if envelope.kind == "Deferred" then
			fixture.input.owner.Destroy()
		end
	end)

	Utils.wake(fixture, 0.625001)
	expect(#fixture.envelopes).toBe(count + 1)
	expect(Utils.ids(fixture)).toEqual({})
	expect(Utils.pending(fixture)).toBe(0)
end)
