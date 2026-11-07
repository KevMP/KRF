--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local Types = require(ReplicatedStorage.Packages.KRF.client.Action.types)
local InputTypes = require(ReplicatedStorage.Packages.KRF.client.Input.types)
local Owner = require(ReplicatedStorage.Packages.KRF.client.Action.ClientActionOwner)
local SequenceUtils = require(script.Parent.Utils.SequenceTestUtils)
local Utils = require(script.Parent.Utils.ActionRouteTestUtils)
local fixture: Utils.Fixture

beforeEach(function()
	fixture = Utils.new()
end)

afterEach(function()
	Utils.destroy(fixture)
end)

for _, gesture: "DoubleTapped" | "Held" | "LongHeld" in { "DoubleTapped", "Held", "LongHeld" } do
	it("forwards the original live Bool epoch for " .. gesture .. " without selecting an activation policy", function()
		expect({
			fixture.input.input.owner.SetSource("Gestures", {
				gestures = {
					X = {
						DoubleTapped = { maxTapDurationSeconds = 0.25, maxGapSeconds = 0.5 },
						Held = { afterSeconds = 0.5 },
						LongHeld = { afterSeconds = 1 },
					},
				},
			}),
		}).toEqual({ true })

		Utils.set(fixture, { Utils.fixed(Utils.key("X", gesture)) })
		Utils.select(fixture)

		if gesture == "DoubleTapped" then
			Utils.press(fixture, 0)
		end

		Utils.emit(fixture, 0.125)

		if gesture ~= "DoubleTapped" then
			SequenceUtils.wake(fixture.input, if gesture == "Held" then 0.625 else 1.125)
		end

		expect(#fixture.selections).toBe(1)
		local selected: Types.ActionRouteSelection = fixture.selections[1]
		local hold: InputTypes.RecognitionHoldOwner = assert(selected.holdOwner, "Expected exact live hold provenance")
		expect(hold.inputId).toBe("X")
		expect(hold.isActiveAfterCommit).toBe(true)
		expect(fixture.input.input.owner.IsPressEpochActive("X", hold.pressEpochId, hold.inputGeneration)).toBe(true)
		expect((selected :: any).activation).toBeNil()
		Utils.emit(fixture, 2, "X", "Released")
		expect(fixture.input.input.owner.IsPressEpochActive("X", hold.pressEpochId, hold.inputGeneration)).toBe(false)
	end)
end

it("captures only final Z's live epoch for immediate X Q Z and leaves the original release observable", function()
	expect({ SequenceUtils.install(fixture.input, { Fireball = SequenceUtils.pattern({ "X", "Q", "Z" }) }) }).toEqual({
		true,
	})

	Utils.set(fixture, { Utils.fixed({ kind = "Sequence", sequenceId = "Fireball" }, "Technique.Charge") })
	Utils.select(fixture)
	SequenceUtils.play(fixture.input, { "X", "Q" })
	Utils.emit(fixture, 0.25, "Z")
	local selected: Types.ActionRouteSelection = fixture.selections[1]
	local root: InputTypes.RootCandidateEnvelope = SequenceUtils.lastRoot(fixture.input)

	expect(selected.holdOwner).toEqual({
		inputId = "Z",
		inputGeneration = root.inputGeneration,
		pressEpochId = root.rootInputEpochId,
		isActiveAfterCommit = true,
	})

	Utils.press(fixture, 0.375, "X")
	local hold: InputTypes.RecognitionHoldOwner = assert(selected.holdOwner, "Expected final Z owner")
	expect(fixture.input.input.owner.IsPressEpochActive("Z", hold.pressEpochId, hold.inputGeneration)).toBe(true)
	Utils.emit(fixture, 0.5, "Z", "Released")
	expect(fixture.input.input.owner.IsPressEpochActive("Z", hold.pressEpochId, hold.inputGeneration)).toBe(false)
	expect(fixture.input.input.events[#fixture.input.input.events]).toMatchObject({ kind = "Released", inputId = "Z" })
	expect(#fixture.selections).toBe(1)
end)

for _, origin: string in { "BoolPress", "BoolRelease", "Analog", "Deadline" } do
	it("forwards framework-verified custom ownership for " .. origin .. " and ignores forged metadata", function()
		local definition: InputTypes.RecognizerDefinition = SequenceUtils.recognizer(
			function(context: InputTypes.RecognizerContext, event: InputTypes.RecognizerEvent): InputTypes.CustomMatch?
				if origin == "Deadline" then
					if event.kind == "Pressed" then
						context:ScheduleAfter(0.25)
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

		definition.onDeadline = function(): InputTypes.CustomMatch?
			return {}
		end

		expect({ fixture.input.input.owner.SetSource("Custom", { recognizers = { Motion = definition } }) }).toEqual({
			true,
		})

		Utils.set(fixture, { Utils.fixed({ kind = "Custom", recognizerId = "Motion" }) })
		Utils.select(fixture)

		if origin == "Analog" then
			Utils.emit(fixture, 0, "Aim", "StateChanged", Vector2.new(1, 0))
		elseif origin == "BoolRelease" then
			Utils.press(fixture, 0)
		else
			Utils.emit(fixture, 0)
		end

		if origin == "Deadline" then
			SequenceUtils.wake(fixture.input, 0.250001)
		end

		expect(#fixture.selections).toBe(1)
		local selected: Types.ActionRouteSelection = fixture.selections[1]

		if origin == "BoolPress" then
			local hold: InputTypes.RecognitionHoldOwner =
				assert(selected.holdOwner, "Expected verified native X ownership")

			expect(hold.inputId).toBe("X")
			expect(hold.pressEpochId == 999).toBe(false)
		else
			expect(selected.holdOwner).toBeNil()
		end
	end)
end

for _, activation: string in { "OneShot", "WhileDown" } do
	for _, releasedAt: number in { 0.25, 0.5 } do
		it(
			"lets mock I6 evaluate " .. activation .. " after late Held resolution at release " .. tostring(releasedAt),
			function()
				expect({
					fixture.input.input.owner.SetSource(
						"Gestures",
						{ gestures = { X = { Held = { afterSeconds = 0.25 }, Tap = { maxDurationSeconds = 1 } } } }
					),
				}).toEqual({ true })

				local resolved: number = 0

				Utils.set(fixture, {
					Utils.dynamic(Utils.key("X", "Held"), function(): Types.ResolvedAction?
						resolved += 1

						return { actionId = "Game." .. activation }
					end),
					Utils.fixed(Utils.key("X", "Tap")),
				})

				local released: boolean = false

				fixture.input.input.owner.ObservePrimitive(
					"Routing",
					function(occurrence: InputTypes.PrimitiveOccurrence): ()
						if occurrence.event.kind == "Released" then
							released = true
						end
					end
				)

				local admitted: number = 0

				fixture.onSink = function(selection: Types.ActionRouteSelection): ()
					expect(released).toBe(true)
					expect(selection.actionId).toBe("Game." .. activation)
					local root: InputTypes.InputCandidateEnvelope = selection.envelope
					assert(root.kind == "Root", "Expected release root")
					expect(root.lifecycleDelivered).toBe(true)
					expect(root.isRootEpochActiveAfterCommit).toBe(false)
					local hold: InputTypes.RecognitionHoldOwner? = selection.holdOwner

					if
						activation == "WhileDown"
						and (
							hold == nil
							or not fixture.input.input.owner.IsPressEpochActive(
								hold.inputId,
								hold.pressEpochId,
								hold.inputGeneration
							)
						)
					then
						return
					end

					admitted += 1
				end

				Utils.select(fixture)
				Utils.emit(fixture, 0)
				Utils.emit(fixture, releasedAt, "X", "Released")
				expect(resolved).toBe(1)
				expect(admitted).toBe(if activation == "OneShot" then 1 else 0)
				expect(Utils.actions(fixture)).toEqual({ "Game." .. activation })
				expect(fixture.input.events[1].gesture).toBe("Held")
			end
		)
	end
end

it("gives a Tap selection no WhileDown owner while retaining the released epoch as recognition truth", function()
	expect({
		fixture.input.input.owner.SetSource("Gestures", { gestures = { X = { Tap = { maxDurationSeconds = 0.25 } } } }),
	}).toEqual({ true })

	Utils.set(fixture, { Utils.fixed(Utils.key("X", "Tap")) })
	Utils.select(fixture)
	Utils.press(fixture, 0)
	expect(#fixture.selections).toBe(1)
	expect(fixture.selections[1].holdOwner).toBeNil()
	expect(fixture.selections[1].candidate.kind).toBe("Input")
end)

-- Inject only the finalized private envelope seam. All input epochs, graph
-- references and recognizer definitions still come from the real I1-I3 owner.
local function captureReceiver(): (InputTypes.InputCandidateEnvelope) -> ()
	fixture.owner.Destroy()
	local receive: ((InputTypes.InputCandidateEnvelope) -> ())? = nil

	local input: InputTypes.InputOwner = table.clone(fixture.options.Input)

	input.ObserveCandidateEnvelope = function(callback: (InputTypes.InputCandidateEnvelope) -> ()): () -> ()
		receive = callback

		return function(): () end
	end

	fixture.options.Input = input
	fixture.owner = Owner.new(fixture.options)

	return assert(receive, "Expected synchronous finalized-envelope subscription")
end

for _, provenance: string in { "DifferentRoot", "Deferred", "NotImmediate" } do
	it("never masks an Input lane using equal timestamps with " .. provenance .. " provenance", function()
		expect({ SequenceUtils.install(fixture.input, { Combo = SequenceUtils.pattern({ "X" }) }) }).toEqual({ true })
		local receive = captureReceiver()
		Utils.set(fixture, { Utils.fixed(), Utils.fixed({ kind = "Sequence", sequenceId = "Combo" }, "Combo") })
		Utils.select(fixture)
		Utils.emit(fixture, 0)
		local root: InputTypes.RootCandidateEnvelope = SequenceUtils.lastRoot(fixture.input)
		local changed: any = table.clone(root)
		local candidates: { InputTypes.RecognitionCandidate } = {}

		for _, candidate: InputTypes.RecognitionCandidate in root.candidates do
			local copy: any = table.clone(candidate)

			if copy.kind == "Sequence" then
				copy.rootInputOrdinal = if provenance == "DifferentRoot"
					then root.rootInputOrdinal + 100
					else root.rootInputOrdinal

				copy.immediate = provenance == "DifferentRoot"
				copy.holdOwner = nil
			end

			table.insert(candidates, table.freeze(copy) :: InputTypes.RecognitionCandidate)
		end

		changed.candidates = table.freeze(candidates)

		if provenance == "Deferred" then
			-- A deferred result and an unrelated native root can share a timestamp.
			local deferred: InputTypes.DeferredCandidateEnvelope = {
				kind = "Deferred",
				occurrenceOrdinal = root.occurrenceOrdinal + 1,
				timestamp = root.timestamp,
				inputGeneration = root.inputGeneration,
				causeRootInputOrdinal = root.rootInputOrdinal,
				candidates = { candidates[2] },
			}

			local native: any = table.clone(root)
			native.candidates = table.freeze({ candidates[1] })
			receive(table.freeze(native))
			receive(table.freeze(deferred))
		else
			receive(table.freeze(changed))
		end

		local actions: { string } = Utils.actions(fixture)
		table.sort(actions)
		expect(actions).toEqual({ "Combat.Punch", "Combo" })
	end)
end

it("deduplicates repeated candidates and duplicate delivery within one occurrence and selection generation", function()
	local receive = captureReceiver()
	Utils.set(fixture, { Utils.fixed() })
	Utils.select(fixture)
	Utils.emit(fixture, 0)
	local root: InputTypes.RootCandidateEnvelope = SequenceUtils.lastRoot(fixture.input)

	local envelope: any = table.clone(root)
	envelope.candidates = table.freeze({ root.candidates[1], root.candidates[1] })
	receive(table.freeze(envelope))
	receive(envelope)
	expect(Utils.actions(fixture)).toEqual({ "Combat.Punch" })
	Utils.select(fixture, fixture.other)
	receive(envelope)
	expect(Utils.actions(fixture)).toEqual({ "Combat.Punch" })
end)

it("preserves a held input's originating epoch generation across an unrelated committed graph change", function()
	expect({
		fixture.input.input.owner.SetSource("Gestures", { gestures = { X = { Held = { afterSeconds = 0.25 } } } }),
	}).toEqual({ true })

	Utils.set(fixture, { Utils.fixed(Utils.key("X", "Held")) })
	Utils.select(fixture)
	Utils.emit(fixture, 0)
	local root: InputTypes.RootCandidateEnvelope = SequenceUtils.lastRoot(fixture.input)
	expect({ fixture.input.input.owner.SetContextEnabled("Aim", false) }).toEqual({ true })
	SequenceUtils.wake(fixture.input, 0.25)
	expect(#fixture.selections).toBe(1)
	local selected: Types.ActionRouteSelection = fixture.selections[1]

	expect(selected.holdOwner).toEqual({
		inputId = "X",
		inputGeneration = root.rootInputEpochGeneration,
		pressEpochId = root.rootInputEpochId,
		isActiveAfterCommit = true,
	})

	expect(selected.envelope.inputGeneration > root.inputGeneration).toBe(true)
end)
