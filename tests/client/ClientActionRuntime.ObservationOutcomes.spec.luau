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
local Registry = require(KRF.client.Actor.utils.ActorViewRegistryState)
local Requests = require(KRF.client.ActionRequest.utils.ClientActionRequestState)
local Constants = require(KRF.shared.Networking.utils.CommandConstants)
local Client = require(KRF.client)
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

for _, status: "Accepted" | "Rejected" in { "Accepted", "Rejected" } do
	it("correlates Unknown to late " .. status .. " using the same key without replay", function()
		assert(Runtime.RequestAction(fixture.actor, "Combat.Fireball", { aim = 1 }))
		fixture.clock.Advance(Constants.TIMEOUT_SECONDS)
		fixture.clock.Advance(Constants.GRACE_SECONDS / 2)
		Utils.result(fixture, 1, "Start", status, 91, if status == "Rejected" then "ActionNotGranted" else nil)
		task.wait()

		expect(Utils.kinds(capture.private)).toEqual({
			"RequestAdmitted:Start",
			"RequestOutcome:Start",
			"RequestOutcome:Start",
		})

		local start: Types.ActionRequestEvent = Utils.fact(capture.private, 1)

		expect(Utils.fact(capture.private, 2)).toMatchObject({
			status = "Unknown",
			requestId = 1,
			requestKey = start.originalStartKey,
		})

		local definitive: Types.ActionRequestEvent = Utils.fact(capture.private, 3)

		expect(definitive).toMatchObject({
			status = status,
			requestId = 1,
			requestKey = start.originalStartKey,
			originalStartKey = start.originalStartKey,
			actor = fixture.actor,
			actionId = "Combat.Fireball",
			eventOrdinal = 3,
		})

		assert(definitive.kind == "RequestOutcome", "Expected definitive request outcome")
		expect(definitive.sequenceId).toBe(if status == "Accepted" then 91 else nil)
		expect(definitive.reason).toBe(if status == "Rejected" then "ActionNotGranted" else nil)
		expect(#fixture.commands.sent).toBe(1)
		expect(assert(Requests.Get()):_GetRetainedCountForTests()).toBe(0)
		Utils.parity(capture)
	end)
end

it("ignores a definitive result beyond I5 grace without extending its metadata lifetime", function()
	assert(Runtime.RequestAction(fixture.actor, "Combat.Fireball", { aim = 1 }))
	fixture.clock.Advance(Constants.TIMEOUT_SECONDS)
	fixture.clock.Advance(Constants.GRACE_SECONDS)
	Utils.result(fixture, 1, "Start", "Accepted", 8)
	task.wait()
	expect(Utils.kinds(capture.private)).toEqual({ "RequestAdmitted:Start", "RequestOutcome:Start" })
	expect(Utils.fact(capture.private, 2)).toMatchObject({ status = "Unknown" })
	expect(assert(Requests.Get()):_GetRetainedCountForTests()).toBe(0)
	Utils.parity(capture)
end)

it("keeps identical Action IDs and Actor-scoped sequence IDs distinct after control changes", function()
	assert(Runtime.RequestAction(fixture.actor, "Combat.Fireball", { aim = 1 }))
	assert(Runtime.RequestAction(fixture.actor, "Combat.Fireball", { aim = 2 }))
	assert(Runtime.RequestAction(fixture.other, "Combat.Fireball", { aim = 3 }))
	assert(Runtime.SetControlledActor(fixture.other))

	for _, id: number in { 3, 1, 2 } do
		Utils.result(fixture, id, "Start", "Accepted", if id == 2 then 8 else 7)
		task.wait()
	end

	for index, id: number in { 3, 1, 2 } do
		local admitted: Types.ActionRequestEvent = Utils.fact(capture.private, id)
		local outcome: Types.ActionRequestEvent = Utils.fact(capture.private, 3 + index)

		expect(outcome).toMatchObject({
			requestId = id,
			requestKey = admitted.originalStartKey,
			actor = if id == 3 then fixture.other else fixture.actor,
			actionId = "Combat.Fireball",
			sequenceId = if id == 2 then 8 else 7,
		})
	end

	expect(capture.private[1].originalStartKey).never.toBe(capture.private[2].originalStartKey)
	Utils.parity(capture)
end)

it("publishes a legitimate pending outcome for the original unavailable Actor without reviving it", function()
	Input.set(fixture, { Input.route("Combat.Fireball") })
	Input.tap(fixture)
	Registry.Invalidate(fixture.actor, "ActorUnavailable")
	expect(fixture.actor:IsAvailable()).toBe(false)
	Utils.result(fixture, 1, "Start", "Accepted", 31)
	task.wait()
	expect(Utils.kinds(capture.private)).toEqual({ "RequestAdmitted:Start", "RequestOutcome:Start" })

	expect(Utils.fact(capture.private, 2)).toMatchObject({
		actor = fixture.actor,
		actionId = "Combat.Fireball",
		status = "Accepted",
		sequenceId = 31,
		origin = "Input",
	})

	expect(fixture.actor:IsAvailable()).toBe(false)
	expect(Runtime.GetControlledActor()).toBeNil()
	expect(assert(Requests.Get()):_GetRetainedCountForTests()).toBe(0)
	Utils.parity(capture)
end)

it("does not interpret a missing ActionsView entry as denial or terminal state", function()
	assert(Runtime.RequestAction(fixture.actor, "Combat.Fireball", { aim = 1 }))
	Utils.result(fixture, 1, "Start", "Accepted", 71)
	task.wait()
	expect(fixture.actor:GetActions():IsActionActive("Combat.Fireball")).toBe(false)
	expect(Utils.kinds(capture.private)).toEqual({ "RequestAdmitted:Start", "RequestOutcome:Start" })
	expect(Utils.fact(capture.private, 2)).toMatchObject({ status = "Accepted", sequenceId = 71 })
	Utils.parity(capture)
end)

it("preserves an admitted Stop Unknown without automatic retry or invented end", function()
	Input.set(fixture, { Input.route("Combat.Rasengan") })
	Input.tap(fixture)
	Utils.result(fixture, 1, "Start", "Accepted", 4)
	task.wait()
	fixture.clock.Advance(Constants.TIMEOUT_SECONDS)

	expect(Utils.kinds(capture.private)).toEqual({
		"RequestAdmitted:Start",
		"GenuineRelease",
		"RequestAdmitted:Stop",
		"RequestOutcome:Start",
		"RequestOutcome:Stop",
	})

	expect(Utils.fact(capture.private, 5)).toMatchObject({
		operation = "Stop",
		status = "Unknown",
		requestId = 2,
		originalStartRequestId = 1,
	})

	expect(#fixture.commands.sent).toBe(2)
	Utils.parity(capture)
end)

it("passes through I5-issued Closing Unknown then fences old private subscriptions and stale replies", function()
	assert(Runtime.RequestAction(fixture.actor, "Combat.Fireball", { aim = 1 }))
	local inbound = assert(fixture.commands.client.inbound, "Expected old reliable receiver")
	Client._ResetForTests()
	expect(Utils.kinds(capture.private)).toEqual({ "RequestAdmitted:Start", "RequestOutcome:Start" })

	expect(Utils.fact(capture.private, 2)).toMatchObject({
		status = "Unknown",
		reason = "CommandConnectionClosed",
		actor = fixture.actor,
		originalStartRequestId = 1,
	})

	local count: number = #capture.private
	-- The old receiver is deliberately retained by the fixture, as a transport
	-- completion may still hold it after the client disposed the connection.
	local currentInbound = fixture.commands.client.inbound

	fixture.commands.client.inbound = inbound
	Utils.result(fixture, 1, "Start", "Accepted", 5)
	fixture.commands.client.inbound = currentInbound
	task.wait()
	expect(#capture.private).toBe(count)
	expect({ Runtime.RequestAction(fixture.actor, "Combat.Fireball", { aim = 1 }) }).toEqual({ nil, "ClientNotReady" })
end)

it("reuses numeric IDs across Client.Init incarnations with different opaque original keys", function()
	assert(Runtime.RequestAction(fixture.actor, "Combat.Fireball", { aim = 1 }))
	local first: Types.ActionRequestEvent = Utils.fact(capture.private, 1)
	Input.destroy(fixture)
	fixture = Input.new()
	Input.ready(fixture, Input.policies())
	local nextCapture: Utils.Capture = Utils.capture()
	assert(Runtime.RequestAction(fixture.actor, "Combat.Fireball", { aim = 2 }))
	local second: Types.ActionRequestEvent? = nextCapture.private[1]
	nextCapture.disconnect()
	expect(second ~= nil).toBe(true)
	assert(second ~= nil, "Expected new incarnation admission")
	expect(second).toMatchObject({ requestId = 1, originalStartRequestId = 1, eventOrdinal = 1 })
	expect(type(second.originalStartKey)).toBe("string")
	expect(second.originalStartKey).never.toBe(first.originalStartKey)
	expect(first.actor).never.toBe(second.actor)
	-- The old private subscriber receives Closing but cannot follow a new owner.
	expect(#capture.private).toBe(2)
end)
