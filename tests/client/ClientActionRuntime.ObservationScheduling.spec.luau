--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local Types = require(KRF.client.Action.types)
local SignalTypes = require(KRF.shared.Signal.types)
local Runtime: Types.ClientActionRuntime = require(KRF.client.Action.ClientActionRuntime)
local State = require(KRF.client.Action.utils.ClientActionRuntimeState)
local Requests = require(KRF.client.ActionRequest.utils.ClientActionRequestState)
local Client = require(KRF.client)
local Input = require(script.Parent.Utils.ActionInputTestUtils)
local Utils = require(script.Parent.Utils.ActionObservationTestUtils)
local fixture: Input.Fixture
local capture: Utils.Capture
local connections: { SignalTypes.Connection }
local disconnects: { () -> () }
local gate: BindableEvent

beforeEach(function()
	fixture = Input.new()
	Input.ready(fixture, Input.policies())
	capture = Utils.capture()
	connections, disconnects = {}, {}
	gate = Instance.new("BindableEvent")
end)

afterEach(function()
	gate:Fire()
	gate:Destroy()

	for _, connection in connections do
		connection:Disconnect()
	end

	for _, disconnect in disconnects do
		disconnect()
	end

	capture.disconnect()
	Input.destroy(fixture)
end)

it("keeps a current projection from regressing when an admission callback resumes after its outcome", function()
	local arrival: { string } = {}
	local projection: { [string]: { ordinal: number, kind: string } } = {}

	table.insert(
		connections,
		Runtime.OnActionRequest:Connect(function(fact: Types.ActionRequestEvent): ()
			if fact.kind == "RequestAdmitted" then
				gate.Event:Wait()
			end

			table.insert(arrival, fact.kind)
			local current = projection[fact.originalStartKey]

			if current == nil or fact.eventOrdinal > current.ordinal then
				projection[fact.originalStartKey] = { ordinal = fact.eventOrdinal, kind = fact.kind }
			end
		end)
	)

	assert(Runtime.RequestAction(fixture.actor, "Combat.Fireball", { aim = 1 }))
	Utils.result(fixture, 1, "Start", "Accepted", 7)
	task.wait()
	gate:Fire()
	task.wait()
	expect(arrival).toEqual({ "RequestOutcome", "RequestAdmitted" })
	local original: Types.ActionRequestEvent = Utils.fact(capture.private, 1)
	expect(projection[original.originalStartKey]).toEqual({ ordinal = 2, kind = "RequestOutcome" })
	expect(Utils.kinds(capture.private)).toEqual({ "RequestAdmitted:Start", "RequestOutcome:Start" })
end)

it("retains every distinct local decision on the ordered path despite a delayed public admission", function()
	Input.set(fixture, { Input.route("Combat.Rasengan") })
	local arrival: { string } = {}

	table.insert(
		connections,
		Runtime.OnActionRequest:Connect(function(fact: Types.ActionRequestEvent): ()
			if fact.kind == "RequestAdmitted" and fact.operation == "Start" then
				gate.Event:Wait()
			end

			table.insert(
				arrival,
				if fact.kind == "InputTransition" then fact.transition else fact.kind .. ":" .. fact.operation
			)
		end)
	)

	Input.tap(fixture)
	task.wait()
	gate:Fire()
	task.wait()
	expect(arrival).toEqual({ "GenuineRelease", "RequestAdmitted:Stop", "RequestAdmitted:Start" })
	expect(Utils.kinds(capture.private)).toEqual({ "RequestAdmitted:Start", "GenuineRelease", "RequestAdmitted:Stop" })
	Utils.parity(capture)
end)

it("allows public reentry and unsubscribe without changing already committed identities", function()
	local reentered: boolean = false
	local connection: SignalTypes.Connection?

	connection = Runtime.OnActionRequest:Connect(function(fact: Types.ActionRequestEvent): ()
		if fact.kind == "RequestAdmitted" and not reentered then
			reentered = true
			assert(connection, "Expected public subscription"):Disconnect()
			Runtime.RequestAction(fixture.other, "Combat.Fireball", { aim = 2 })
		end
	end)

	table.insert(connections, connection)
	assert(Runtime.RequestAction(fixture.actor, "Combat.Fireball", { aim = 1 }))
	task.wait()
	expect(reentered).toBe(true)
	expect(#fixture.commands.sent).toBe(2)
	expect(Utils.fact(capture.private, 1)).toMatchObject({ actor = fixture.actor, requestId = 1, eventOrdinal = 1 })
	expect(Utils.fact(capture.private, 2)).toMatchObject({ actor = fixture.other, requestId = 2, eventOrdinal = 2 })
	Utils.parity(capture)
end)

it("permits an already-running public callback to resume after reset with its old immutable key", function()
	local resumed: Types.ActionRequestEvent? = nil

	table.insert(
		connections,
		Runtime.OnActionRequest:Connect(function(fact: Types.ActionRequestEvent): ()
			if fact.kind == "RequestAdmitted" then
				gate.Event:Wait()
				resumed = fact
			end
		end)
	)

	assert(Runtime.RequestAction(fixture.actor, "Combat.Fireball", { aim = 1 }))
	task.wait()
	Client._ResetForTests()
	gate:Fire()
	task.wait()
	local original: Types.ActionRequestEvent = Utils.fact(capture.private, 1)
	expect(resumed).toBe(original)
	expect(table.isfrozen(assert(resumed, "Expected resumed public fact"))).toBe(true)
	expect(original.actor:IsAvailable()).toBe(false)
end)

it("stops observations at safe-integer ordinal exhaustion while I5 continues sending", function()
	State._SetObservationOrdinalForTests(9007199254740990)

	for _ = 1, 3 do
		assert(Runtime.RequestAction(fixture.actor, "Combat.Fireball", { aim = 1 }))
	end

	expect(#fixture.commands.sent).toBe(3)
	expect(#capture.private).toBe(1)
	expect(Utils.fact(capture.private, 1).eventOrdinal).toBe(9007199254740991)
	Utils.parity(capture)
end)

it("bounds private subscriptions and reclaims their slots after disconnection", function()
	-- capture owns one slot. The limit is private and matches the existing I5 seam.
	for _ = 1, 15 do
		table.insert(disconnects, State.ObserveActionRequest(function(): () end))
	end

	expect(function()
		State.ObserveActionRequest(function(): () end)
	end).toThrow()

	disconnects[1]()
	disconnects[1]()
	table.insert(disconnects, State.ObserveActionRequest(function(): () end))
	assert(Runtime.RequestAction(fixture.actor, "Combat.Fireball", { aim = 1 }))
	expect(#capture.private).toBe(1)
end)

it("returns request retention to baseline across more completed OneShot requests than the live bound", function()
	local requests = assert(Requests.Get())

	for index = 1, 70 do
		local id: number = assert(Runtime.RequestAction(fixture.actor, "Combat.Fireball", { aim = 1 }))
		Utils.result(fixture, id, "Start", "Accepted", index)
		task.wait()
		expect(requests:_GetRetainedCountForTests()).toBe(0)
		fixture.clock.Advance(0.02)
	end

	expect(#capture.private).toBe(140)
	Utils.parity(capture)
end)
