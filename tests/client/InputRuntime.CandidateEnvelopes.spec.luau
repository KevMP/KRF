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

it("publishes one immutable root envelope before public callbacks even without recognizers", function()
	Utils.emit(fixture, 0, "X")
	expect(#fixture.envelopes).toBe(1)
	local envelope: Types.RootCandidateEnvelope = Utils.lastRoot(fixture)
	expect(envelope.rootInputId).toBe("X")
	expect(envelope.rootContextId).toBe("Signs")
	expect(envelope.rootInputOrdinal).toBe(fixture.input.events[1].ordinal)
	expect(envelope.isRootEpochActiveAfterCommit).toBe(true)
	expect(envelope.lifecycleDelivered).toBe(true)

	expect({
		fixture.input.owner.IsPressEpochActive(
			"X",
			assert(envelope.rootInputEpochId, "Expected Bool press epoch"),
			envelope.inputGeneration
		),
	}).toEqual({ true })

	expect(table.isfrozen(envelope)).toBe(true)
	expect(table.isfrozen(envelope.candidates)).toBe(true)
	expect(table.isfrozen(envelope.candidates[1])).toBe(true)
	expect(fixture.trace).toEqual({ "Envelope:Root", "Input:Pressed" })
end)

it("merges immediate primitive, custom and sequence lanes once without global category selection", function()
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

	expect({
		Utils.install(fixture, {
			Short = Utils.pattern({ "X" }),
			FromCustom = Utils.pattern({ { recognizerId = "Sign", kind = "Custom" } }),
		}),
	}).toEqual({ true })

	Utils.emit(fixture, 0, "X")
	expect(#fixture.envelopes).toBe(1)
	local envelope: Types.RootCandidateEnvelope = Utils.lastRoot(fixture)
	local identities: { string } = {}

	for _, candidate: Types.RecognitionCandidate in envelope.candidates do
		if candidate.kind == "Input" then
			table.insert(identities, "Input:" .. candidate.inputId .. ":" .. candidate.gesture)
		elseif candidate.kind == "Sequence" then
			table.insert(identities, "Sequence:" .. candidate.sequenceId)
		else
			table.insert(identities, "Custom:" .. candidate.recognizerId)
		end
	end

	table.sort(identities)
	expect(identities).toEqual({ "Custom:Sign", "Input:X:Pressed", "Sequence:FromCustom", "Sequence:Short" })
	expect(Utils.ids(fixture)).toEqual({ "FromCustom", "Short" })
	expect(#fixture.recognizers).toBe(1)
end)

it("retains I2 DoubleTapped preference and recognized-but-ineligible second-release Tap", function()
	expect({
		fixture.input.owner.SetSource("Gestures", {
			gestures = {
				Q = {
					Tap = { maxDurationSeconds = 0.25 },
					DoubleTapped = { maxTapDurationSeconds = 0.25, maxGapSeconds = 0.5 },
				},
			},
		}),
	}).toEqual({ true })

	Utils.press(fixture, 0, "Q")
	Utils.emit(fixture, 0.125, "Q")
	local press: Types.RootCandidateEnvelope = Utils.lastRoot(fixture)
	expect(press.inputPolicy).toBe("PreferSpecific")
	local keys: { string } = {}

	for _, candidate: Types.RecognitionCandidate in press.candidates do
		assert(candidate.kind == "Input", "Expected I2 input lane")
		table.insert(keys, candidate.gesture)
	end

	expect(keys).toEqual({ "DoubleTapped", "Pressed" })
	Utils.emit(fixture, 0.25, "Q", "Released")
	local release: Types.RootCandidateEnvelope = Utils.lastRoot(fixture)
	expect(release.isRootEpochActiveAfterCommit).toBe(false)
	expect(#release.candidates).toBe(1)
	local tap: Types.RecognitionCandidate = release.candidates[1]
	assert(tap.kind == "Input", "Expected Tap lane")
	expect(tap.gesture).toBe("Tap")
	expect(tap.routeEligible).toBe(false)
	expect(#fixture.events).toBe(3)
end)

it("commits release liveness before the envelope containing caught-up Held recognition", function()
	expect({ fixture.input.owner.SetSource("Gestures", { gestures = { X = { Held = { afterSeconds = 0.25 } } } }) }).toEqual({
		true,
	})

	local lifecycle: boolean = false

	fixture.input.owner.ObservePrimitive("Routing", function(occurrence: Types.PrimitiveOccurrence): ()
		if occurrence.event.kind == "Released" then
			lifecycle = true
		end
	end)

	local checked: boolean = false

	fixture.input.owner.ObserveCandidateEnvelope(function(envelope: Types.InputCandidateEnvelope): ()
		if envelope.kind == "Root" and not envelope.isRootEpochActiveAfterCommit then
			expect(lifecycle).toBe(true)
			expect(envelope.lifecycleDelivered).toBe(true)
			checked = true
		end
	end)

	Utils.emit(fixture, 0, "X")
	Utils.emit(fixture, 0.5, "X", "Released")
	expect(checked).toBe(true)
	expect(#fixture.envelopes).toBe(2)
	expect(fixture.events[1].gesture).toBe("Held")
	expect(Utils.lastRoot(fixture).isRootEpochActiveAfterCommit).toBe(false)
end)

it("anchors an immediate X Q Z match only to the verified final Z press epoch", function()
	expect({ Utils.install(fixture, { Combo = Utils.pattern({ "X", "Q", "Z" }) }) }).toEqual({ true })
	Utils.play(fixture, { "X", "Q" })
	Utils.emit(fixture, 0.25, "Z")
	local envelope: Types.RootCandidateEnvelope = Utils.lastRoot(fixture)
	local matched: boolean = false

	for _, candidate: Types.RecognitionCandidate in envelope.candidates do
		if candidate.kind == "Sequence" then
			expect(candidate.sequenceId).toBe("Combo")
			expect(candidate.immediate).toBe(true)
			expect(candidate.rootInputOrdinal).toBe(envelope.rootInputOrdinal)

			expect(candidate.holdOwner).toEqual({
				inputId = "Z",
				inputGeneration = envelope.inputGeneration,
				pressEpochId = envelope.rootInputEpochId,
				isActiveAfterCommit = true,
			})

			expect(table.isfrozen(assert(candidate.holdOwner, "Expected verified hold owner"))).toBe(true)
			matched = true
		end
	end

	expect(matched).toBe(true)
end)

for _, origin: string in { "BoolPress", "BoolRelease", "Analog", "Deadline" } do
	it("verifies custom hold ownership for " .. origin .. " instead of trusting metadata", function()
		local definition: Types.RecognizerDefinition = Utils.recognizer(
			function(ctx: Types.RecognizerContext, event: Types.RecognizerEvent): Types.CustomMatch?
				if origin == "Deadline" then
					if event.kind == "Pressed" then
						ctx:ScheduleAfter(0.25)
					end

					return nil
				end

				if origin == "BoolPress" and event.kind ~= "Pressed" then
					return nil
				end

				if origin == "BoolRelease" and event.kind ~= "Released" then
					return nil
				end

				return { metadata = { inputId = "Q", pressEpochId = 999, inputGeneration = -1 } }
			end
		)

		if origin == "Analog" then
			definition.inputs = { "Aim" }
		end

		definition.onDeadline = function(): Types.CustomMatch?
			return {}
		end

		expect({ fixture.input.owner.SetSource("Custom", { recognizers = { Sign = definition } }) }).toEqual({ true })

		if origin == "Analog" then
			Utils.emit(fixture, 0, "Aim", "StateChanged", Vector2.new(1, 0))
		elseif origin == "BoolRelease" then
			Utils.press(fixture, 0, "X")
		else
			Utils.emit(fixture, 0, "X")
		end

		if origin == "Deadline" then
			Utils.wake(fixture, 0.250001)
		end

		local envelope: Types.InputCandidateEnvelope = fixture.envelopes[#fixture.envelopes]
		local found: boolean = false

		for _, candidate: Types.RecognitionCandidate in envelope.candidates do
			if candidate.kind == "Custom" then
				found = true

				if origin == "BoolPress" then
					expect(assert(candidate.holdOwner, "Expected verified hold owner").inputId).toBe("X")
					expect(assert(candidate.holdOwner, "Expected verified hold owner").pressEpochId == 999).toBe(false)
				else
					expect(candidate.holdOwner).toBeNil()
				end

				expect(candidate.immediate).toBe(origin ~= "Deadline")
			end
		end

		expect(found).toBe(true)
		expect(envelope.kind).toBe(if origin == "Deadline" then "Deferred" else "Root")
	end)
end

it("gives delayed I2 Tap a new envelope without active epoch or causal-root masking", function()
	expect({
		fixture.input.owner.SetSource("Gestures", {
			gestures = {
				X = {
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

	expect({ Utils.install(fixture, { Combo = Utils.pattern({ { inputId = "X", kind = "Tap" } }) }) }).toEqual({ true })
	Utils.press(fixture, 0, "X")
	local previous: number = fixture.envelopes[#fixture.envelopes].occurrenceOrdinal
	Utils.wake(fixture, 0.500001)
	local envelope: Types.InputCandidateEnvelope = fixture.envelopes[#fixture.envelopes]
	assert(envelope.kind == "Deferred", "Expected deferred emission")
	expect(envelope.occurrenceOrdinal > previous).toBe(true)
	expect(envelope.causeRootInputOrdinal).toBe(fixture.input.events[2].ordinal)
	expect((envelope :: any).rootInputEpochId).toBeNil()
	local found: boolean = false

	for _, candidate: Types.RecognitionCandidate in envelope.candidates do
		if candidate.kind == "Sequence" then
			expect(candidate.immediate).toBe(false)
			expect(candidate.holdOwner).toBeNil()
			found = true
		end
	end

	expect(found).toBe(true)
end)

for _, mode: string in { "Throw", "Yield" } do
	it("contains routing observer " .. mode .. " without rewriting recognition or fallback", function()
		expect({ Utils.install(fixture, { Combo = Utils.pattern({ "X" }) }) }).toEqual({ true })
		local lateCalls: number = 0

		fixture.input.owner.ObserveCandidateEnvelope(function(): ()
			if mode == "Throw" then
				error("InjectedRoutingFault")
			else
				coroutine.yield()
			end
		end)

		fixture.input.owner.ObserveCandidateEnvelope(function(): ()
			lateCalls += 1
		end)

		Utils.emit(fixture, 0, "X")
		expect(Utils.ids(fixture)).toEqual({ "Combo" })
		expect(#fixture.input.events).toBe(1)
		expect(#fixture.envelopes).toBe(1)
		expect(lateCalls).toBe(0)
		expect(#fixture.input.faults).toBe(1)
	end)
end

it("disconnects an observer before later occurrences and is safe to disconnect twice", function()
	local calls: number = 0

	local disconnect = fixture.input.owner.ObserveCandidateEnvelope(function(): ()
		calls += 1
	end)

	Utils.emit(fixture, 0, "X")
	disconnect()
	disconnect()
	Utils.emit(fixture, 0.125, "Q")
	expect(calls).toBe(1)
	fixture.input.owner.Destroy()
	disconnect()
end)

it("queues source changes requested by a recognizer behind the complete current occurrence", function()
	local requested: boolean = false

	expect({
		fixture.input.owner.SetSource("Custom", {
			recognizers = {
				Mutator = Utils.recognizer(
					function(_ctx: Types.RecognizerContext, event: Types.RecognizerEvent): Types.CustomMatch?
						if event.kind == "Pressed" then
							expect({
								fixture.input.owner.SetSource(
									"Later",
									{ sequences = { Later = Utils.pattern({ "X" }) } }
								),
							}).toEqual({ true })

							expect(fixture.input.owner.GetSequence("Later")).toBeNil()
							requested = true
						end

						return nil
					end
				),
			},
		}),
	}).toEqual({ true })

	Utils.press(fixture, 0, "X")
	expect(requested).toBe(true)
	expect(Utils.ids(fixture)).toEqual({})
	expect({ fixture.input.owner.GetSequence("Later") ~= nil }).toEqual({ true })
	Utils.press(fixture, 0.125, "X")
	expect(Utils.ids(fixture)).toEqual({ "Later" })
end)

it("isolates a late DeferredTap expired by the next press from that press's live root", function()
	expect({
		fixture.input.owner.SetSource("Gestures", {
			gestures = {
				X = {
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

	expect({ Utils.install(fixture, { TapSequence = Utils.pattern({ { inputId = "X", kind = "Tap" } }) }) }).toEqual({
		true,
	})

	Utils.press(fixture, 0, "X")
	local count: number = #fixture.envelopes
	Utils.emit(fixture, 1, "X")
	expect(#fixture.envelopes).toBe(count + 2)
	local deferred: Types.InputCandidateEnvelope = fixture.envelopes[count + 1]
	expect(deferred.kind).toBe("Deferred")

	for _, candidate: Types.RecognitionCandidate in deferred.candidates do
		if candidate.kind == "Sequence" then
			expect(candidate.immediate).toBe(false)
			expect(candidate.holdOwner).toBeNil()
		end
	end

	local root: Types.RootCandidateEnvelope = Utils.lastRoot(fixture)
	expect(root.isRootEpochActiveAfterCommit).toBe(true)
	expect(#root.candidates).toBe(1)
	local pressed: Types.RecognitionCandidate = root.candidates[1]
	assert(pressed.kind == "Input", "Expected primitive candidate")
	expect(pressed.gesture).toBe("Pressed")
	expect(Utils.ids(fixture)).toEqual({ "TapSequence" })
end)

it("disconnects observers within the current immutable envelope snapshot", function()
	local laterCalls: number = 0
	local disconnect: () -> () = function() end

	fixture.input.owner.ObserveCandidateEnvelope(function(): ()
		disconnect()
	end)

	disconnect = fixture.input.owner.ObserveCandidateEnvelope(function(): ()
		laterCalls += 1
	end)

	Utils.emit(fixture, 0, "X")
	expect(laterCalls).toBe(0)
	expect(#fixture.input.events).toBe(1)
end)

it("stops remaining observers and public delivery after terminal teardown inside an envelope", function()
	local laterCalls: number = 0

	fixture.input.owner.ObserveCandidateEnvelope(function(): ()
		fixture.input.owner.Destroy()
	end)

	fixture.input.owner.ObserveCandidateEnvelope(function(): ()
		laterCalls += 1
	end)

	Utils.emit(fixture, 0, "X")
	expect(laterCalls).toBe(0)
	expect(#fixture.input.events).toBe(0)
	expect(fixture.input.connections).toBe(0)
end)
