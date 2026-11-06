--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local Types = require(ReplicatedStorage.Packages.KRF.client.Input.types)
local Utils = require(script.Parent.Utils.SequenceTestUtils)
local InputUtils = require(script.Parent.Utils.InputTestUtils)
local fixture: Utils.Fixture

beforeEach(function()
	fixture = Utils.new()
end)

afterEach(function()
	Utils.destroy(fixture)
end)

it("leaves all recognition histories intact when reset preparation is rejected", function()
	expect({ fixture.input.owner.SetSource("Manual", Utils.deferred()) }).toEqual({ true })
	Utils.play(fixture, { "X", "Q" })
	local pending: number = Utils.pending(fixture)

	local plan: Types.PreparedRecognitionReset?, reason: string? =
		fixture.input.owner.PrepareRecognitionReset({ "Missing" }, "ActorChanged")

	expect(plan).toBeNil()
	expect(reason).toBe("UnknownInput")
	expect(Utils.pending(fixture)).toBe(pending)
	expect(Utils.ids(fixture)).toEqual({})
	Utils.wake(fixture, 0.625001)
	expect(Utils.ids(fixture)).toEqual({ "Short" })
end)

it("preserves live partials when a staged native update rolls back before publication", function()
	expect({ fixture.input.owner.SetSource("Manual", Utils.deferred()) }).toEqual({ true })
	Utils.play(fixture, { "X", "Q" })
	fixture.input.failAt[#fixture.input.writes + 1] = true

	local source: Types.InputSourceDefinition = Utils.deferred()

	-- Allocation fails before any installed input is retired.
	local combined: Types.InputSourceDefinition = {
		sequences = source.sequences,
		sequenceGroups = source.sequenceGroups,
		contexts = { Extra = { priority = 1, sink = false } },
		inputs = { NewInput = { context = "Extra", type = Enum.InputActionType.Bool, bindings = {} } },
	}

	expect({ fixture.input.owner.SetSource("Manual", combined) }).toEqual({ false, "NativeCommitFailed" })
	expect(fixture.input.owner.GetInput("NewInput")).toBeNil()
	expect(assert(fixture.input.owner.GetSequence("Short"), "Expected old recognition graph").sourceId).toBe("Manual")
	Utils.wake(fixture, 0.625001)
	expect(Utils.ids(fixture)).toEqual({ "Short" })
end)

it("terminal native failure retires sequence and custom deadlines without publishing pending results", function()
	expect({ fixture.input.owner.SetSource("Manual", Utils.deferred()) }).toEqual({ true })

	expect({
		fixture.input.owner.SetSource("Custom", {
			recognizers = {
				Timed = Utils.recognizer(
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

	Utils.play(fixture, { "X", "Q" })
	local callbacks: { () -> () } = {}

	for _, job in fixture.jobs do
		table.insert(callbacks, job.callback)
	end

	fixture.input.native.Destroy = function(): ()
		error("InjectedRetirementFailure")
	end

	-- A private terminal native failure is exercised on an unrelated owned input.
	expect({
		fixture.input.owner.SetSource(
			"Temporary",
			{ inputs = { Temporary = { context = "Signs", type = Enum.InputActionType.Bool, bindings = {} } } }
		),
	}).toEqual({ true })

	expect({ fixture.input.owner.RemoveSource("Temporary") }).toEqual({ false, "InputRuntimeFaulted" })
	expect(Utils.pending(fixture)).toBe(0)
	expect(fixture.input.owner.GetSequence("Short")).toBeNil()
	expect(fixture.input.owner.GetRecognizer("Timed")).toBeNil()
	fixture.input.now = 10

	for _, callback in callbacks do
		callback()
	end

	expect(Utils.ids(fixture)).toEqual({})
	expect(#fixture.recognizers).toBe(0)
	expect(fixture.input.connections).toBe(0)
end)

it("resets selected custom windows while unrelated scalar history survives", function()
	local seen: { [string]: { boolean } } = { X = {}, Z = {} }

	local function definition(id: string): Types.RecognizerDefinition
		local result: Types.RecognizerDefinition = Utils.recognizer(
			function(ctx: Types.RecognizerContext, event: Types.RecognizerEvent): Types.CustomMatch?
				if event.kind == "Pressed" then
					table.insert(seen[id], ctx:GetState("seen") == true)
					ctx:SetState("seen", true)
				end

				return nil
			end
		)

		result.inputs = { id }

		return result
	end

	expect({
		fixture.input.owner.SetSource(
			"Custom",
			{ recognizers = { First = definition("X"), Second = definition("Z") } }
		),
	}).toEqual({ true })

	Utils.play(fixture, { "X", "Z" })
	expect({ fixture.input.owner.ResetRecognition({ "X" }, "ActorChanged") }).toEqual({ true })
	Utils.play(fixture, { "X", "Z" }, 0.25)
	expect(seen).toEqual({ X = { false, false }, Z = { false, true } })
end)

it("keeps immediate same-root custom alternatives from advancing a mixed lineage twice", function()
	expect({
		fixture.input.owner.SetSource(
			"Gestures",
			{ gestures = { Q = { DoubleTapped = { maxTapDurationSeconds = 0.25, maxGapSeconds = 0.5 } } } }
		),
	}).toEqual({ true })

	local definition: Types.RecognizerDefinition = Utils.recognizer(
		function(_ctx: Types.RecognizerContext, event: Types.RecognizerEvent): Types.CustomMatch?
			return if event.kind == "Pressed" or event.kind == "Gesture" then {} else nil
		end
	)

	definition.inputs = { "Q" }
	definition.gestures = { Q = { "DoubleTapped" } }
	expect({ fixture.input.owner.SetSource("Custom", { recognizers = { Sign = definition } }) }).toEqual({ true })
	Utils.press(fixture, 0, "Q")

	expect({
		Utils.install(fixture, {
			Combo = Utils.pattern({
				{ inputId = "Q", kind = "DoubleTapped" },
				{ recognizerId = "Sign", kind = "Custom" },
			}),
		}),
	}).toEqual({ true })

	local previous: number = #fixture.recognizers
	Utils.emit(fixture, 0.125, "Q")
	expect(#fixture.recognizers).toBe(previous + 1)
	expect(Utils.ids(fixture)).toEqual({})
end)

it("commits recognition reset and epoch invalidation before any controls have been installed", function()
	Utils.destroy(fixture)
	fixture.input = InputUtils.new()

	local reset: Types.PreparedRecognitionReset? = fixture.input.owner.PrepareRecognitionReset(nil, "ActorChanged")
	local invalidation: Types.PreparedInputInvalidation? = fixture.input.owner.PrepareEpochInvalidation("ActorChanged")

	expect({
		fixture.input.owner.CommitEpochInvalidation(assert(invalidation, "Expected epoch plan"), function(): ()
			expect({ fixture.input.owner.CommitPreparedRecognitionReset(assert(reset, "Expected reset plan")) }).toEqual({
				true,
			})
		end),
	}).toEqual({ true })

	expect(Utils.pending(fixture)).toBe(0)
end)

it("keeps a prepared reset valid across axis input that no recognition owner watches", function()
	expect({ fixture.input.owner.SetSource("Manual", Utils.deferred()) }).toEqual({ true })
	Utils.play(fixture, { "X", "Q" })

	local reset: Types.PreparedRecognitionReset? = fixture.input.owner.PrepareRecognitionReset(nil, "ActorChanged")
	local invalidation: Types.PreparedInputInvalidation? = fixture.input.owner.PrepareEpochInvalidation("ActorChanged")

	Utils.emit(fixture, 0.25, "Aim", "StateChanged", Vector2.new(1, 0))

	local outcome: { any } = {}

	expect({
		fixture.input.owner.CommitEpochInvalidation(assert(invalidation, "Expected epoch plan"), function(): ()
			outcome = { fixture.input.owner.CommitPreparedRecognitionReset(assert(reset, "Expected reset plan")) }
		end),
	}).toEqual({ true })

	expect(outcome).toEqual({ true })
	expect(Utils.pending(fixture)).toBe(0)
end)

it("rejects a prepared reset after a watched axis event changes recognizer state", function()
	expect({
		fixture.input.owner.SetSource("Custom", {
			recognizers = {
				Track = {
					inputs = { "Aim" },
					maxWindowSeconds = 1,
					onEvent = function(): Types.CustomMatch?
						return nil
					end,
				},
			},
		}),
	}).toEqual({ true })

	local reset: Types.PreparedRecognitionReset? = fixture.input.owner.PrepareRecognitionReset(nil, "ActorChanged")
	local invalidation: Types.PreparedInputInvalidation? = fixture.input.owner.PrepareEpochInvalidation("ActorChanged")

	Utils.emit(fixture, 0.25, "Aim", "StateChanged", Vector2.new(1, 0))

	local outcome: { any } = {}

	expect({
		fixture.input.owner.CommitEpochInvalidation(assert(invalidation, "Expected epoch plan"), function(): ()
			outcome = { fixture.input.owner.CommitPreparedRecognitionReset(assert(reset, "Expected reset plan")) }
		end),
	}).toEqual({ true })

	expect(outcome).toEqual({ false, "StaleRecognitionReset" })
end)
