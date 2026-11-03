--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage.Packages.KRF.client.Input.types)
local InputUtils = require(script.Parent.InputTestUtils)
local GestureUtils = require(script.Parent.GestureTestUtils)

export type Fixture = GestureUtils.Fixture & {
	sequences: { Types.SequenceMatchEvent },
	recognizers: { Types.CustomRecognitionEvent },
	envelopes: { Types.InputCandidateEnvelope },
	trace: { string },
}

local Utils = {}

function Utils.new(): Fixture
	local jobs: { GestureUtils.Job } = {}
	local gestures: { Types.GestureEvent } = {}
	local sequences: { Types.SequenceMatchEvent } = {}
	local recognizers: { Types.CustomRecognitionEvent } = {}
	local trace: { string } = {}

	local input: InputUtils.Fixture = InputUtils.new({
		Scheduler = {
			Schedule = function(deadline: number, callback: () -> ()): () -> ()
				local job: GestureUtils.Job =
					{ deadline = deadline, callback = callback, cancelled = false, fired = false }

				table.insert(jobs, job)

				return function(): ()
					job.cancelled = true
				end
			end,
		},
		PublishGesture = function(event: Types.GestureEvent): ()
			table.insert(trace, "Gesture:" .. event.gesture)
			table.insert(gestures, event)
		end,
		PublishSequence = function(event: Types.SequenceMatchEvent): ()
			table.insert(trace, "Sequence:" .. event.sequenceId)
			table.insert(sequences, event)
		end,
		PublishRecognizer = function(event: Types.CustomRecognitionEvent): ()
			table.insert(trace, "Custom:" .. event.recognizerId)
			table.insert(recognizers, event)
		end,
	})

	local fixture: Fixture = {
		input = input,
		events = gestures,
		groups = {},
		jobs = jobs,
		sequences = sequences,
		recognizers = recognizers,
		envelopes = {},
		trace = trace,
	}

	input.now = 0

	input.onPublish = function(event: Types.SemanticInputEvent): ()
		table.insert(trace, "Input:" .. event.kind)
	end

	input.owner.ObserveCandidateEnvelope(function(envelope: Types.InputCandidateEnvelope): ()
		table.insert(trace, "Envelope:" .. envelope.kind)
		table.insert(fixture.envelopes, envelope)
	end)

	input.owner.ObserveDispatchGroup(function(group: Types.GestureDispatchGroup): ()
		table.insert(fixture.groups, group)
	end)

	local inputs: { [string]: Types.InputDefinition } = {}

	for _, id: string in { "X", "Q", "Z", "A", "C", "Attack" } do
		inputs[id] = {
			context = "Signs",
			type = Enum.InputActionType.Bool,
			bindings = { Keyboard = { keyCode = Enum.KeyCode.Space } },
		}
	end

	inputs.Aim = { context = "Aim", type = Enum.InputActionType.Direction2D, bindings = {} }

	assert(input.owner.SetSource("Core", {
		contexts = { Signs = { priority = 2000, sink = true }, Aim = { priority = 1, sink = false } },
		inputs = inputs,
	}))

	assert(input.owner.SetContextEnabled("Signs", true))
	assert(input.owner.SetContextEnabled("Aim", true))

	return fixture
end

function Utils.pattern(steps: { Types.SequenceStep }, gap: number?, total: number?): Types.SequenceDefinition
	local owned: { Types.SequenceStep } = {}

	for _, step in steps do
		table.insert(owned, step)
	end

	return { steps = owned, maxGapSeconds = gap or 0.5, maxTotalSeconds = total or 2 }
end

function Utils.install(
	fixture: Fixture,
	sequences: { [string]: Types.SequenceDefinition },
	sourceId: string?
): (boolean, string?)
	return fixture.input.owner.SetSource(sourceId or "Manual", { sequences = sequences })
end

function Utils.deferred(): Types.InputSourceDefinition
	return {
		sequenceGroups = {
			Signs = {
				policy = "DeferredPrefix",
				maxGapSeconds = 0.5,
				maxTotalSeconds = 2,
				scope = { "X", "Q", "Z", "A", "C" },
			},
		},
		sequences = {
			Short = { steps = { "X", "Q" }, exclusiveGroup = "Signs" },
			Long = { steps = { "X", "Q", "Z" }, exclusiveGroup = "Signs" },
			Longest = { steps = { "X", "Q", "Z", "A" }, exclusiveGroup = "Signs" },
		},
	}
end

function Utils.recognizer(
	callback: (Types.RecognizerContext, Types.RecognizerEvent) -> Types.CustomMatch?
): Types.RecognizerDefinition
	return { inputs = { "X" }, maxWindowSeconds = 1, onEvent = callback }
end

function Utils.emit(fixture: Fixture, time: number, id: string, kind: Types.NativeTransition?, value: any?): ()
	fixture.input.now = time

	local transition: Types.NativeTransition = kind or "Pressed"
	InputUtils.emit(fixture.input, transition, if value ~= nil then value else transition == "Pressed", id)
end

function Utils.press(fixture: Fixture, time: number, id: string): ()
	Utils.emit(fixture, time, id, "Pressed")
	Utils.emit(fixture, time, id, "Released")
end

function Utils.play(fixture: Fixture, ids: { string }, start: number?, gap: number?): ()
	for index: number, id: string in ids do
		Utils.press(fixture, (start or 0) + (index - 1) * (gap or 0.125), id)
	end
end

function Utils.ids(fixture: Fixture): { string }
	local ids: { string } = {}

	for _, event: Types.SequenceMatchEvent in fixture.sequences do
		table.insert(ids, event.sequenceId)
	end

	return ids
end

function Utils.lastRoot(fixture: Fixture): Types.RootCandidateEnvelope
	local envelope: Types.InputCandidateEnvelope =
		assert(fixture.envelopes[#fixture.envelopes], "Expected finalized envelope")

	assert(envelope.kind == "Root", "Expected root envelope")

	return envelope
end

Utils.wake = GestureUtils.wake
Utils.pending = GestureUtils.pending
Utils.destroy = GestureUtils.destroy

return Utils
