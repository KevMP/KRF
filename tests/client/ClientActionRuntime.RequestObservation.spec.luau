--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local Types = require(KRF.client.Action.types)
local Runtime: Types.ClientActionRuntime = require(KRF.client.Action.ClientActionRuntime)
local State = require(KRF.client.Action.utils.ClientActionRuntimeState)
local Input = require(script.Parent.Utils.ActionInputTestUtils)
local Utils = require(script.Parent.Utils.ActionObservationTestUtils)
local fixture: Input.Fixture
local capture: Utils.Capture

beforeEach(function()
	fixture = Input.new()
	Input.ready(fixture, Input.policies())
	capture = Utils.capture()
end)

afterEach(function()
	capture.disconnect()
	Input.destroy(fixture)
end)

it("adds exactly one read-only Event to the stable frozen Action facade", function()
	expect(table.isfrozen(Runtime)).toBe(true)
	local members: { string } = {}

	for key: string in Runtime do
		table.insert(members, key)
	end

	table.sort(members)

	expect(members).toEqual({
		"GetControlledActor",
		"GetEffectiveRoute",
		"GetProfileSources",
		"OnActionRequest",
		"RemoveProfileSource",
		"RequestAction",
		"RequestInterrupt",
		"RequestStop",
		"RetireRequest",
		"SetControlledActor",
		"SetProfileSource",
	})

	for _, key: string in { "Fire", "Destroy", "DisconnectAll", "Signal" } do
		expect((pcall(function(): ()
			local _value = (Runtime.OnActionRequest :: any)[key]
		end))).toBe(false)
	end
end)

it("reports a frozen Direct admission before RequestAction returns without input provenance", function()
	local original: number = assert(Runtime.RequestAction(fixture.actor, "Combat.Fireball", { aim = 9 }))
	local fact: Types.ActionRequestEvent = Utils.fact(capture.private, 1)

	expect(fact).toEqual({
		kind = "RequestAdmitted",
		operation = "Start",
		requestId = original,
		requestKey = (fact :: Types.ActionRequestAdmitted).requestKey,
		originalStartRequestId = original,
		originalStartKey = fact.originalStartKey,
		actor = fixture.actor,
		actionId = "Combat.Fireball",
		origin = "Direct",
		eventOrdinal = 1,
		observedAt = 100,
	})

	expect(type(fact.originalStartKey)).toBe("string")
	expect(#fact.originalStartKey > 0).toBe(true)
	expect((fact :: Types.ActionRequestAdmitted).requestKey).toBe(fact.originalStartKey)
	expect(table.isfrozen(fact)).toBe(true)

	expect((pcall(function(): ()
		(fact :: any).actionId = "Combat.Rasengan"
	end))).toBe(false)

	Utils.parity(capture)
end)

it("uses the original input clock and never publishes payloads, policy hooks or recognition objects", function()
	Input.set(fixture, { Input.route("Combat.Rasengan") })
	fixture.inputTime = 12.5
	Input.emit(fixture, "Pressed")
	local fact: Types.ActionRequestEvent = Utils.fact(capture.private, 1)

	expect(fact).toMatchObject({
		kind = "RequestAdmitted",
		operation = "Start",
		requestId = 1,
		requestKey = fact.originalStartKey,
		originalStartRequestId = 1,
		originalStartKey = fact.originalStartKey,
		actor = fixture.actor,
		actionId = "Combat.Rasengan",
		origin = "Input",
		eventOrdinal = 1,
		observedAt = 100,
		inputOccurredAt = 12.5,
	})

	Utils.parity(capture)
end)

it("gives manual follow-ups their own keys while retaining the input Start's identity and origin", function()
	Input.set(fixture, { Input.route("Combat.Rasengan") })
	Input.emit(fixture, "Pressed")
	expect({ Runtime.RequestStop(1, { releaseAim = 8 }) }).toEqual({ 2 })
	Input.emit(fixture, "Released")
	Input.emit(fixture, "Pressed")
	expect({ Runtime.RequestInterrupt(3, "FocusLost") }).toEqual({ 4 })

	expect(Utils.kinds(capture.private)).toEqual({
		"RequestAdmitted:Start",
		"RequestAdmitted:Stop",
		"RequestAdmitted:Start",
		"RequestAdmitted:Interrupt",
	})

	for _, index: number in { 2, 4 } do
		local start: Types.ActionRequestEvent = Utils.fact(capture.private, index - 1)
		local follow: Types.ActionRequestEvent = Utils.fact(capture.private, index)

		expect(follow).toMatchObject({
			actor = fixture.actor,
			actionId = "Combat.Rasengan",
			origin = "Input",
			originalStartRequestId = index - 1,
			originalStartKey = start.originalStartKey,
			requestId = index,
			eventOrdinal = index,
		})

		assert(follow.kind == "RequestAdmitted", "Expected follow-up admission")
		expect(follow.requestKey).never.toBe(start.originalStartKey)
		expect(follow.inputOccurredAt).toBeNil()
	end

	expect((capture.private[2] :: Types.ActionRequestAdmitted).requestKey).never.toBe(
		(capture.private[4] :: Types.ActionRequestAdmitted).requestKey
	)

	Utils.parity(capture)
end)

it("surfaces real sequence IDs only for Accepted Start and keeps outcomes as immutable facts", function()
	assert(Runtime.RequestAction(fixture.actor, "Combat.Rasengan", { aim = 1 }))
	assert(Runtime.RequestStop(1, { releaseAim = 2 }))
	assert(Runtime.RequestInterrupt(1, "FocusLost"))

	for index, operation: Types.ActionRequestOperation in { "Start", "Stop", "Interrupt" } do
		Utils.result(fixture, index, operation, "Accepted", 77)
		task.wait()
		local fact: Types.ActionRequestEvent = Utils.fact(capture.private, 3 + index)

		expect(fact).toMatchObject({
			kind = "RequestOutcome",
			operation = operation,
			status = "Accepted",
			requestId = index,
			eventOrdinal = 3 + index,
		})

		assert(fact.kind == "RequestOutcome", "Expected authoritative request outcome")
		expect(fact.sequenceId).toBe(if operation == "Start" then 77 else nil)
		expect(fact.requestKey).toBe((capture.private[index] :: Types.ActionRequestAdmitted).requestKey)
		expect(table.isfrozen(fact)).toBe(true)
	end

	Utils.parity(capture)
end)

it("takes a deferred Start timestamp from its selected I4 candidate without fabricating a hold", function()
	assert(fixture.input.SetSource("DeferredTap", {
		gestures = {
			X = {
				Tap = { maxDurationSeconds = 0.25 },
				DoubleTapped = { maxTapDurationSeconds = 0.25, maxGapSeconds = 0.5, arbitration = "DeferredTap" },
			},
		},
	}))

	Input.set(fixture, { Input.route("Combat.Fireball", Input.key("X", "Tap")) })
	local selected: Types.ActionRouteSelection?

	local stop = assert(State.Get(), "Expected installed routing owner").ObserveSelection(
		function(selection: Types.ActionRouteSelection): ()
			selected = selection
		end
	)

	Input.emit(fixture, "Pressed", "X")
	fixture.clock.Advance(0.125)
	Input.emit(fixture, "Released", "X")
	expect(#capture.private).toBe(0)
	fixture.clock.Advance(0.75)
	stop()
	local selection: Types.ActionRouteSelection = assert(selected, "Expected deferred I4 selection")
	expect(selection.envelope.kind).toBe("Deferred")
	expect(selection.holdOwner).toBeNil()
	expect(#Input.packets(fixture)).toBe(1)

	expect(Utils.fact(capture.private, 1)).toMatchObject({
		kind = "RequestAdmitted",
		operation = "Start",
		origin = "Input",
		inputOccurredAt = selection.envelope.timestamp,
		actionId = "Combat.Fireball",
	})

	Utils.parity(capture)
end)
