--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local Types = require(ReplicatedStorage.Packages.KRF.client.Input.types)
local InputTestUtils = require(script.Parent.Utils.InputTestUtils)
local Utils = require(script.Parent.Utils.GestureTestUtils)
local fixture: Utils.Fixture

beforeEach(function()
	fixture = Utils.new()
end)

afterEach(function()
	Utils.destroy(fixture)
end)

for _, mode: string in { "FirstTap", "DeferredTap", "Held", "ConsumedPair" } do
	it("silently resets " .. mode .. " state synchronously and idempotently", function()
		local definitions: Types.GestureDefinitions = Utils.pair(if mode == "DeferredTap" then "DeferredTap" else nil)
		definitions.Held = { afterSeconds = 1 }
		expect(Utils.install(fixture, definitions)).toBe(true)

		if mode == "Held" then
			Utils.emit(fixture, 0, "Pressed")
		else
			Utils.tap(fixture, 0, 0.125)

			if mode == "ConsumedPair" then
				Utils.emit(fixture, 0.25, "Pressed")
			end
		end

		local recognized: number = #fixture.events
		local primitives: number = #fixture.input.events
		expect({ fixture.input.owner.ResetRecognition({ "Primary" }, "ActorChanged") }).toEqual({ true })
		expect({ fixture.input.owner.ResetRecognition({ "Primary" }, "ActorChanged") }).toEqual({ true })
		Utils.wake(fixture, 5)
		expect(#fixture.events).toBe(recognized)
		expect(#fixture.input.events).toBe(primitives)
		expect(Utils.pending(fixture)).toBe(0)
	end)
end

it("does not mutate recognition or timers while preparing an abandoned reset", function()
	expect(Utils.install(fixture, Utils.pair("DeferredTap"))).toBe(true)
	Utils.tap(fixture, 0, 0.125)
	local pending: number = Utils.pending(fixture)

	local plan: Types.PreparedRecognitionReset?, reason: string? =
		fixture.input.owner.PrepareRecognitionReset(nil, "ActorChanged")

	expect(reason).toBeNil()
	expect(plan ~= nil).toBe(true)
	expect(Utils.pending(fixture)).toBe(pending)
	expect(Utils.kinds(fixture)).toEqual({})
	Utils.emit(fixture, 0.25, "Pressed")
	expect(Utils.kinds(fixture)).toEqual({ "DoubleTapped" })
end)

it("commits prepared reset with I1 invalidation before publishing a new selection", function()
	expect(Utils.install(fixture, Utils.pair("DeferredTap"))).toBe(true)
	Utils.tap(fixture, 0, 0.125)
	local plan: Types.PreparedRecognitionReset? = fixture.input.owner.PrepareRecognitionReset(nil, "ActorChanged")
	expect(plan ~= nil).toBe(true)
	local invalidation: Types.PreparedInputInvalidation? = fixture.input.owner.PrepareEpochInvalidation("ActorChanged")
	local published: boolean = false

	expect(fixture.input.owner.CommitEpochInvalidation(assert(invalidation, "Expected I1 plan"), function()
		expect({ fixture.input.owner.CommitPreparedRecognitionReset(assert(plan, "Expected reset plan")) }).toEqual({
			true,
		})

		published = true
	end)).toBe(true)

	expect(published).toBe(true)
	Utils.emit(fixture, 0.25, "Pressed")
	expect(Utils.kinds(fixture)).toEqual({})
	Utils.wake(fixture, 1)
	expect(Utils.kinds(fixture)).toEqual({})
end)

it("requires the I1 commit fence for a prepared reset", function()
	local plan: Types.PreparedRecognitionReset? = fixture.input.owner.PrepareRecognitionReset(nil, "ActorChanged")
	expect(plan ~= nil).toBe(true)

	expect({ fixture.input.owner.CommitPreparedRecognitionReset(assert(plan, "Expected reset plan")) }).toEqual({
		false,
		"InputCommitFenceRequired",
	})
end)

it("leaves physical epoch liveness to I1 after recognition-only reset", function()
	expect(Utils.install(fixture, { Held = { afterSeconds = 1 } })).toBe(true)
	local press: Types.PrimitiveOccurrence? = nil

	fixture.input.owner.ObservePrimitive("Routing", function(occurrence: Types.PrimitiveOccurrence)
		press = occurrence
	end)

	Utils.emit(fixture, 0, "Pressed")
	expect({ fixture.input.owner.ResetRecognition(nil, "ActorChanged") }).toEqual({ true })
	local occurrence: Types.PrimitiveOccurrence = assert(press, "Expected press")

	expect(
		fixture.input.owner.IsPressEpochActive(
			"Primary",
			assert(occurrence.pressEpochId, "Expected epoch"),
			occurrence.generation
		)
	).toBe(true)

	Utils.wake(fixture, 2)
	expect(Utils.kinds(fixture)).toEqual({})
end)

it("resets selected inputs while preserving another input's first-tap history", function()
	local second: InputTestUtils.CoreDefinition = {
		contexts = {},
		inputs = { Other = { context = "Gameplay", type = Enum.InputActionType.Bool, bindings = {} } },
	}

	expect(fixture.input.owner.SetSource("Other", second)).toBe(true)

	expect(fixture.input.owner.SetSource("Gestures", { gestures = { Primary = Utils.pair(), Other = Utils.pair() } })).toBe(
		true
	)

	Utils.tap(fixture, 0, 0.0625)
	Utils.tap(fixture, 0.125, 0.1875, "Other")
	expect({ fixture.input.owner.ResetRecognition({ "Primary" }, "ActorChanged") }).toEqual({ true })
	Utils.emit(fixture, 0.25, "Pressed")
	Utils.emit(fixture, 0.3125, "Pressed", "Other")
	expect(Utils.kinds(fixture)).toEqual({ "Tap", "Tap", "DoubleTapped" })
	expect(fixture.events[3].inputId).toBe("Other")
end)

it("rejects a prepared reset from an older input generation under the shared fence", function()
	expect(Utils.install(fixture, Utils.pair())).toBe(true)
	local reset: Types.PreparedRecognitionReset? = fixture.input.owner.PrepareRecognitionReset(nil, "ActorChanged")
	expect(reset ~= nil).toBe(true)
	Utils.tap(fixture, 0, 0.125)
	expect(fixture.input.owner.SetSource("Other", { contexts = { Menu = { priority = 1, sink = false } } })).toBe(true)
	local invalidation: Types.PreparedInputInvalidation? = fixture.input.owner.PrepareEpochInvalidation("ActorChanged")
	local rejected: { any } = {}

	expect(fixture.input.owner.CommitEpochInvalidation(assert(invalidation, "Expected I1 plan"), function()
		rejected = { fixture.input.owner.CommitPreparedRecognitionReset(assert(reset, "Expected reset plan")) }
	end)).toBe(true)

	expect(rejected).toEqual({ false, "StaleRecognitionReset" })
	-- The I1 invalidation itself retires this history; rejection must not emit a gesture.
	expect(Utils.kinds(fixture)).toEqual({ "Tap" })
end)

it("requires I1 neutral rearm before a held control can recognize for the new selection", function()
	expect(Utils.install(fixture, { Tap = { maxDurationSeconds = 1 }, Held = { afterSeconds = 0.5 } })).toBe(true)
	Utils.emit(fixture, 0, "Pressed")
	local reset: Types.PreparedRecognitionReset? = fixture.input.owner.PrepareRecognitionReset(nil, "ActorChanged")
	expect(reset ~= nil).toBe(true)
	local invalidation: Types.PreparedInputInvalidation? = fixture.input.owner.PrepareEpochInvalidation("ActorChanged")

	expect(fixture.input.owner.CommitEpochInvalidation(assert(invalidation, "Expected I1 plan"), function()
		expect({ fixture.input.owner.CommitPreparedRecognitionReset(assert(reset, "Expected reset plan")) }).toEqual({
			true,
		})
	end)).toBe(true)

	Utils.emit(fixture, 0.125, "Pressed")
	Utils.wake(fixture, 1)
	Utils.emit(fixture, 1, "Released")
	expect(Utils.kinds(fixture)).toEqual({})
	Utils.tap(fixture, 2, 2.125)
	expect(Utils.kinds(fixture)).toEqual({ "Tap" })
end)
