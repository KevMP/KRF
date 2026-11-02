--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local Types = require(KRF.client.Input.types)
local Constants = require(KRF.client.Input.utils.InputConstants)
local InputTestUtils = require(script.Parent.Utils.InputTestUtils)
local Utils = require(script.Parent.Utils.GestureTestUtils)
local fixture: Utils.Fixture

beforeEach(function()
	fixture = Utils.new()
end)

afterEach(function()
	Utils.destroy(fixture)
end)

it("accepts the full definition budget and rejects one more before native mutation", function()
	local input: InputTestUtils.Fixture = fixture.input
	local inputs: { [string]: Types.InputDefinition } = {}
	local gestures: { [string]: Types.GestureDefinitions } = {}

	for index: number = 1, Constants.MAX_INPUTS do
		local id: string = "Input" .. index

		inputs[id] = { context = "Gameplay", type = Enum.InputActionType.Bool, bindings = {} }

		gestures[id] = {
			Tap = { maxDurationSeconds = 0.25 },
			Held = { afterSeconds = 0.5 },
			LongHeld = { afterSeconds = 1 },
			DoubleTapped = { maxTapDurationSeconds = 0.25, maxGapSeconds = 0.5 },
		}
	end

	local source: Types.InputSourceDefinition = {
		contexts = { Gameplay = { priority = 0, sink = false } },
		inputs = inputs,
		gestures = gestures,
	}

	local installed: boolean, reason: string? = input.owner.SetSource("Core", source)
	local writes: number = #input.writes

	gestures.Overflow = { Tap = { maxDurationSeconds = 0.25 } }
	local rejected: boolean, rejection: string? = input.owner.SetSource("Core", source)
	local afterWrites: number = #input.writes
	expect({ installed, reason }).toEqual({ true })
	expect({ rejected, rejection }).toEqual({ false, "InputGestureLimitExceeded" })
	expect(afterWrites).toBe(writes)
end)

it("bounds private candidate observers and recovers the slot after disconnection", function()
	local stops: { () -> () } = {}

	-- GestureTestUtils owns the first observer.
	for _ = 2, Constants.MAX_GESTURE_OBSERVERS do
		table.insert(stops, fixture.input.owner.ObserveDispatchGroup(function() end))
	end

	local success: boolean, reason: any = pcall(fixture.input.owner.ObserveDispatchGroup, function() end)
	stops[1]()
	local replacement: () -> () = fixture.input.owner.ObserveDispatchGroup(function() end)
	replacement()
	expect(success).toBe(false)
	expect(tostring(reason)).toContain("InputGestureObserverLimitExceeded")
end)

it("bounds live deadlines during repeated source replacement and cancels all tasks at teardown", function()
	local stale: { Utils.Job } = {}

	for index: number = 1, 32 do
		expect(Utils.install(fixture, { Held = { afterSeconds = index } })).toBe(true)
		Utils.emit(fixture, index * 2, "Pressed")
		expect(Utils.pending(fixture) > 0).toBe(true)
		expect(Utils.pending(fixture) <= Constants.MAX_GESTURE_DEADLINES).toBe(true)

		for _, job: Utils.Job in fixture.jobs do
			if not job.cancelled then
				table.insert(stale, job)
			end
		end

		expect(fixture.input.owner.RemoveSource("Gestures")).toBe(true)
		expect(Utils.pending(fixture)).toBe(0)
		Utils.emit(fixture, index * 2 + 0.125, "Released")
	end

	Utils.destroy(fixture)
	fixture.input.now = 1000

	for _, job: Utils.Job in stale do
		job.callback()
	end

	expect(Utils.kinds(fixture)).toEqual({})
	expect(Utils.pending(fixture)).toBe(0)
end)
