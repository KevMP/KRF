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

it("keeps high-overlap catalogs bounded and emits each identity once per matching occurrence", function()
	local patterns: { [string]: Types.SequenceDefinition } = {}

	for index: number = 1, Constants.MAX_SEQUENCES do
		patterns[string.format("Combo%03d", index)] = Utils.pattern({ "X", "X", "Q" })
	end

	expect({ Utils.install(fixture, patterns) }).toEqual({ true })

	for index: number = 1, 64 do
		Utils.press(fixture, index / 256, "X")
	end

	expect(Utils.pending(fixture) <= Constants.MAX_GESTURE_DEADLINES).toBe(true)
	Utils.emit(fixture, 0.375, "Q")
	expect(#fixture.sequences).toBe(Constants.MAX_SEQUENCES)
	local envelope: Types.RootCandidateEnvelope = Utils.lastRoot(fixture)
	expect(#envelope.candidates <= Constants.MAX_CANDIDATES_PER_OCCURRENCE).toBe(true)
	local ids: { [string]: boolean } = {}

	for _, event: Types.SequenceMatchEvent in fixture.sequences do
		expect(ids[event.sequenceId]).toBeNil()
		ids[event.sequenceId] = true
	end

	expect({ fixture.input.owner.RemoveSource("Manual") }).toEqual({ true })
	expect(Utils.pending(fixture)).toBe(0)
	expect(fixture.input.connections).toBe(7)
end)

it("releases custom deadlines and observer capacity across repeated installation and removal", function()
	for index: number = 1, 16 do
		expect({
			fixture.input.owner.SetSource("Custom", {
				recognizers = {
					Timer = Utils.recognizer(
						function(ctx: Types.RecognizerContext, event: Types.RecognizerEvent): Types.CustomMatch?
							if event.kind == "Pressed" then
								ctx:ScheduleAfter(0.5)
							end

							return nil
						end
					),
				},
			}),
		}).toEqual({ true })

		Utils.press(fixture, index, "X")
		expect(Utils.pending(fixture) > 0).toBe(true)
		expect({ fixture.input.owner.RemoveSource("Custom") }).toEqual({ true })
		expect(Utils.pending(fixture)).toBe(0)
		expect(fixture.input.owner.GetRecognizer("Timer")).toBeNil()
	end

	fixture.input.owner.Destroy()
	expect(fixture.input.connections).toBe(0)
end)

it("enforces observer capacity and makes disconnected slots reusable", function()
	local disconnects: { () -> () } = {}

	-- The fixture already owns one observer.
	for _ = 2, Constants.MAX_CANDIDATE_OBSERVERS do
		table.insert(disconnects, fixture.input.owner.ObserveCandidateEnvelope(function() end))
	end

	local success: boolean, reason: any = pcall(function()
		fixture.input.owner.ObserveCandidateEnvelope(function() end)
	end)

	expect(success).toBe(false)
	expect(string.find(tostring(reason), "InputCandidateObserverLimitExceeded", 1, true) ~= nil).toBe(true)
	disconnects[1]()
	local replacement = fixture.input.owner.ObserveCandidateEnvelope(function() end)
	replacement()

	for _, disconnect in disconnects do
		disconnect()
	end
end)

for _, size: number in { Constants.MAX_SEQUENCE_GROUPS, Constants.MAX_SEQUENCE_GROUPS + 1 } do
	it("enforces the source-local group limit at " .. tostring(size), function()
		local groups: { [string]: Types.SequenceGroupDefinition } = {}
		local sequences: { [string]: Types.SequenceDefinition } = {}

		for index: number = 1, size do
			local name: string = "Group" .. tostring(index)

			groups[name] = { policy = "DeferredPrefix", maxGapSeconds = 0.5, maxTotalSeconds = 2, scope = { "X", "Q" } }
			sequences[name .. "Short"] = { steps = { "X" }, exclusiveGroup = name }
			sequences[name .. "Long"] = { steps = { "X", "Q" }, exclusiveGroup = name }
		end

		expect({ fixture.input.owner.SetSource("Groups", { sequences = sequences, sequenceGroups = groups }) }).toEqual(
			if size <= Constants.MAX_SEQUENCE_GROUPS then { true } else { false, "InputSequenceGroupLimitExceeded" }
		)
	end)
end

for _, size: number in { Constants.MAX_RECOGNIZER_INPUTS, Constants.MAX_RECOGNIZER_INPUTS + 1 } do
	it("enforces the recognizer watched-input limit at " .. tostring(size), function()
		local ids: { string } = {}
		local inputs: { [string]: Types.InputDefinition } = {}

		for index: number = 1, size do
			local id: string = "Watched" .. tostring(index)
			table.insert(ids, id)
			inputs[id] = { context = "Signs", type = Enum.InputActionType.Bool, bindings = {} }
		end

		local definition: Types.RecognizerDefinition = Utils.recognizer(function(): Types.CustomMatch?
			return nil
		end)

		definition.inputs = ids

		local writes: number = #fixture.input.writes

		expect({ fixture.input.owner.SetSource("Custom", { inputs = inputs, recognizers = { Bounded = definition } }) }).toEqual(
			if size <= Constants.MAX_RECOGNIZER_INPUTS then { true } else { false, "InputRecognizerInputLimitExceeded" }
		)

		if size > Constants.MAX_RECOGNIZER_INPUTS then
			expect(#fixture.input.writes).toBe(writes)
		end
	end)
end
