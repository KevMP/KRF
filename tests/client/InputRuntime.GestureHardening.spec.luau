--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local Types = require(KRF.client.Input.types)
local State = require(KRF.client.Input.utils.InputRuntimeState)
local InputTestUtils = require(script.Parent.Utils.InputTestUtils)
local Utils = require(script.Parent.Utils.GestureTestUtils)
local fixture: Utils.Fixture
local custom: InputTestUtils.Fixture? = nil

beforeEach(function()
	fixture = Utils.new()
end)

afterEach(function()
	State.Install(nil)
	State.Disconnect()
	Utils.destroy(fixture)

	if custom ~= nil then
		InputTestUtils.destroy(custom)
		custom = nil
	end
end)

for _, case in
	{
		{ ids = { "Missing" }, reason = "UnknownInput" },
		{ ids = { "Primary", "Primary" }, reason = "InvalidRecognitionResetInputs" },
		{ ids = { bad = "Primary" }, reason = "InvalidRecognitionResetInputs" },
		{ ids = { false }, reason = "InvalidRecognitionResetInputs" },
		{ ids = setmetatable({ "Primary" }, {}), reason = "InvalidRecognitionResetInputs" },
	}
do
	it("rejects invalid reset selection with " .. case.reason .. " without losing pending Tap", function()
		expect(Utils.install(fixture, Utils.pair("DeferredTap"))).toBe(true)
		Utils.tap(fixture, 0, 0.125)
		expect({ fixture.input.owner.ResetRecognition(case.ids :: any, "ManualReset") }).toEqual({ false, case.reason })

		expect({ fixture.input.owner.PrepareRecognitionReset(case.ids :: any, "ManualReset") }).toEqual({
			nil,
			case.reason,
		})

		Utils.wake(fixture, 1)
		expect(Utils.kinds(fixture)).toEqual({ "Tap" })
	end)
end

it("rejects empty reset reasons, closed owners and forged plans with stable errors", function()
	expect({ fixture.input.owner.ResetRecognition(nil, "") }).toEqual({ false, "InvalidRecognitionResetReason" })
	expect({ fixture.input.owner.PrepareRecognitionReset(nil, "") }).toEqual({ nil, "InvalidRecognitionResetReason" })
	local invalidation: Types.PreparedInputInvalidation? = fixture.input.owner.PrepareEpochInvalidation("ActorChanged")
	local forged: Types.PreparedRecognitionReset = { generation = 0, token = {} }
	local result: { any } = {}

	expect(fixture.input.owner.CommitEpochInvalidation(assert(invalidation, "Expected invalidation"), function()
		result = { fixture.input.owner.CommitPreparedRecognitionReset(forged) }
	end)).toBe(true)

	expect(result).toEqual({ false, "InvalidRecognitionReset" })
	fixture.input.owner.Destroy()
	expect({ fixture.input.owner.ResetRecognition(nil, "Reset") }).toEqual({ false, "ClientNotReady" })
	expect({ fixture.input.owner.PrepareRecognitionReset(nil, "Reset") }).toEqual({ nil, "ClientNotReady" })
	expect({ fixture.input.owner.CommitPreparedRecognitionReset(forged) }).toEqual({ false, "ClientNotReady" })
end)

it("rejects synchronous reset reentrancy while leaving the current press eligible", function()
	expect(Utils.install(fixture, { Tap = { maxDurationSeconds = 1 } })).toBe(true)
	local results: { { any } } = {}

	fixture.input.owner.ObservePrimitive("Interpretation", function(occurrence: Types.PrimitiveOccurrence)
		if occurrence.event.kind == "Pressed" then
			table.insert(results, { fixture.input.owner.ResetRecognition(nil, "Reset") })
			table.insert(results, { fixture.input.owner.PrepareRecognitionReset(nil, "Reset") })
		end
	end)

	Utils.tap(fixture, 0, 0.125)
	expect(results).toEqual({ { false, "InputMutationReentrant" }, { nil, "InputMutationReentrant" } })
	expect(Utils.kinds(fixture)).toEqual({ "Tap" })
end)

it("contains public publication errors without undoing recognition or genuine release", function()
	expect(Utils.install(fixture, { Tap = { maxDurationSeconds = 1 } })).toBe(true)

	fixture.onGesture = function(_event: Types.GestureEvent): ()
		error("GesturePublicationFailed", 0)
	end

	Utils.tap(fixture, 0, 0.125)
	expect(Utils.kinds(fixture)).toEqual({ "Tap" })
	expect(fixture.input.events[2].kind).toBe("Released")
	expect(fixture.input.faults).toEqual({ "GesturePublicationFailed" })
	Utils.tap(fixture, 1, 1.125)
	expect(Utils.kinds(fixture)).toEqual({ "Tap", "Tap" })
end)

it("allows public gesture subscribers to yield after synchronous private recognition", function()
	expect(Utils.install(fixture, { Tap = { maxDurationSeconds = 1 } })).toBe(true)
	fixture.onGesture = State.NotifyGesture

	local routed: boolean = false
	local publicEntered: boolean = false
	local worker: thread? = nil

	fixture.input.owner.ObserveDispatchGroup(function(group: Types.GestureDispatchGroup)
		if #group.candidates > 0 and group.candidates[1].key == "Tap" then
			routed = true
		end
	end)

	State.OnGesture:Connect(function()
		publicEntered = routed
		worker = coroutine.running()
		coroutine.yield()
	end)

	Utils.tap(fixture, 0, 0.125)

	if worker ~= nil then
		coroutine.close(worker)
	end

	expect(publicEntered).toBe(true)
	expect(fixture.input.events[2].kind).toBe("Released")
end)

for _, kind: string in { "Held", "LongHeld" } do
	it("retires only a changed active " .. kind .. " and preserves another kind's threshold", function()
		local definitions: Types.GestureDefinitions =
			{ Tap = { maxDurationSeconds = 1 }, Held = { afterSeconds = 0.5 }, LongHeld = { afterSeconds = 0.75 } }

		expect(Utils.install(fixture, definitions)).toBe(true)
		Utils.emit(fixture, 0, "Pressed")

		if kind == "Held" then
			definitions.Held = { afterSeconds = 0.625 }
		else
			definitions.LongHeld = { afterSeconds = 1 }
		end

		expect(Utils.install(fixture, definitions)).toBe(true)
		Utils.wake(fixture, 0.8)
		expect(Utils.kinds(fixture)).toEqual({ if kind == "Held" then "LongHeld" else "Held" })
		Utils.emit(fixture, 0.875, "Released")
		expect(fixture.events[2].gesture).toBe("Tap")
	end)
end

it("retires a changed active deferred pair without completing the old press retrospectively", function()
	expect(Utils.install(fixture, Utils.pair("DeferredTap"))).toBe(true)
	Utils.emit(fixture, 0, "Pressed")
	local replacement: Types.GestureDefinitions = Utils.pair("DeferredTap")
	assert(replacement.DoubleTapped, "Expected pair").maxGapSeconds = 1
	expect(Utils.install(fixture, replacement)).toBe(true)
	Utils.emit(fixture, 0.125, "Released")
	Utils.emit(fixture, 0.25, "Pressed")
	expect(Utils.kinds(fixture)).toEqual({})
end)

it("stops remaining catch-up recognition and public delivery when a private consumer destroys the owner", function()
	expect(
		Utils.install(
			fixture,
			{ Tap = { maxDurationSeconds = 2 }, Held = { afterSeconds = 0.25 }, LongHeld = { afterSeconds = 0.5 } }
		)
	).toBe(true)

	local handled: { string } = {}

	fixture.input.owner.ObserveDispatchGroup(function(group: Types.GestureDispatchGroup)
		if #group.candidates > 0 and group.candidates[1].key == "Held" then
			table.insert(handled, "Held")
			fixture.input.owner.Destroy()
		end
	end)

	fixture.input.owner.ObserveDispatchGroup(function(group: Types.GestureDispatchGroup)
		if #group.candidates > 0 and group.candidates[1].key == "Held" then
			table.insert(handled, "AfterDestroy")
		end
	end)

	Utils.tap(fixture, 0, 1)
	expect(handled).toEqual({ "Held" })
	expect(Utils.kinds(fixture)).toEqual({})
	expect(fixture.input.connections).toBe(0)
end)

it("coalesces multiple timer wakeups behind a native commit before delivering a coherent snapshot", function()
	expect(Utils.install(fixture, { Held = { afterSeconds = 0.25 }, LongHeld = { afterSeconds = 0.5 } })).toBe(true)
	Utils.emit(fixture, 0, "Pressed")
	local jobs: { Utils.Job } = table.clone(fixture.jobs)
	local inside: boolean = false

	fixture.input.owner.ObserveDispatchGroup(function()
		expect(inside).toBe(false)
		expect(fixture.input.owner.GetContext("Other") ~= nil).toBe(true)
	end)

	fixture.input.onWrite = function()
		inside = true
		fixture.input.now = 1

		for _, job: Utils.Job in jobs do
			job.callback()
		end

		inside = false
	end

	expect(fixture.input.owner.SetSource("Other", { contexts = { Other = { priority = 1, sink = false } } })).toBe(true)
	fixture.input.onWrite = nil
	expect(Utils.kinds(fixture)).toEqual({ "Held", "LongHeld" })
	expect(fixture.input.faults).toEqual({})
end)

it("fails closed if scheduling a timer during primitive interpretation throws", function()
	custom = InputTestUtils.new({
		Scheduler = {
			Schedule = function(): () -> ()
				error("SchedulerUnavailable", 0)
			end,
		},
		PublishGesture = function() end,
	})

	local input: InputTestUtils.Fixture = assert(custom, "Expected fixture")
	InputTestUtils.install(input)
	InputTestUtils.enable(input)
	expect(input.owner.SetSource("Held", { gestures = { Primary = { Held = { afterSeconds = 1 } } } })).toBe(true)
	InputTestUtils.emit(input, "Pressed", true)
	expect(input.owner.GetInput("Primary")).toBeNil()
	expect(input.faults[#input.faults]).toBe("InputRuntimeFaulted")
	expect(input.connections).toBe(0)
end)

it("clears gesture queries and deadlines before notifying terminal configuration observers", function()
	expect(Utils.install(fixture, { Held = { afterSeconds = 1 } })).toBe(true)
	Utils.emit(fixture, 0, "Pressed")
	expect(Utils.pending(fixture)).toBe(1)
	local terminal: { [string]: any } = {}

	fixture.input.owner.ObserveConfigurationCommit(function(change: Types.InputGraphChange)
		if change.reasons[1] ~= "InputRuntimeFaulted" then
			error("CommitConsumerFailed", 0)
		end
	end)

	fixture.input.owner.ObserveConfigurationCommit(function(change: Types.InputGraphChange)
		if change.reasons[1] == "InputRuntimeFaulted" then
			terminal = {
				inputAbsent = fixture.input.owner.GetInput("Primary") == nil,
				gesturesAbsent = fixture.input.owner.GetGestures("Primary") == nil,
				pending = Utils.pending(fixture),
			}
		end
	end)

	expect({ fixture.input.owner.SetSource("Other", { contexts = { Other = { priority = 1, sink = false } } }) }).toEqual({
		false,
		"InputRuntimeFaulted",
	})

	expect(terminal).toEqual({ inputAbsent = true, gesturesAbsent = true, pending = 0 })
end)

it("fails closed if an early deferred timer cannot schedule its strictly later replacement", function()
	local fail: boolean = false
	local wake: (() -> ())? = nil

	custom = InputTestUtils.new({
		Scheduler = {
			Schedule = function(_deadline: number, callback: () -> ()): () -> ()
				if fail then
					error("SchedulerUnavailable", 0)
				end

				wake = callback

				return function() end
			end,
		},
		PublishGesture = function() end,
	})

	local input: InputTestUtils.Fixture = assert(custom, "Expected fixture")
	InputTestUtils.install(input)
	InputTestUtils.enable(input)
	expect(input.owner.SetSource("Pair", { gestures = { Primary = Utils.pair("DeferredTap") } })).toBe(true)
	InputTestUtils.emit(input, "Pressed", true)
	input.now += 0.125
	InputTestUtils.emit(input, "Released", false)
	fail = true
	assert(wake, "Expected deferred deadline")()
	expect(input.owner.GetInput("Primary")).toBeNil()
	expect(input.faults[#input.faults]).toBe("InputRuntimeFaulted")
	expect(input.connections).toBe(0)
end)
