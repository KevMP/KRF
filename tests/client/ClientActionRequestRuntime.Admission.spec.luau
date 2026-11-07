--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local afterEach: any = JestGlobals.afterEach
local Types = require(KRF.client.ActionRequest.types)
local ActorTypes = require(KRF.client.Actor.types)
local ActionRequestTypes = require(KRF.shared.ActionRequest.types)
local Constants = require(KRF.shared.ActionRequest.utils.ActionRequestConstants)
local TestUtils = require(script.Parent.Utils.ActionRequestClientTestUtils)
local RequestUtils = require(script.Parent.Parent.shared.Utils.ActionRequestTestUtils)

local fixture: TestUtils.Fixture? = nil

afterEach(function()
	TestUtils.destroy(fixture)
	fixture = nil
end)

local function setup(options: { maxOriginalStarts: number? }?): TestUtils.Fixture
	local created: TestUtils.Fixture = TestUtils.new(nil, options)
	fixture = created

	return created
end

local aim: any = { x = 1, y = 2, z = 3 }

local function admitStart(created: TestUtils.Fixture, actionId: string, parameters: any?): number
	local requestId: number?, reason: string? =
		created.runtime:Start(TestUtils.selection(created, actionId), parameters)

	expect(reason).toBeNil()
	assert(requestId ~= nil, "Expected a locally admitted Start")

	return requestId
end

it("admits a typed Start through the fixed command with the catalog contract and encoded payload", function()
	local created: TestUtils.Fixture = setup()
	local requestId: number = admitStart(created, "Combat.Fireball", { aim = aim })
	local request: ActionRequestTypes.CompiledActionRequest = created.catalog.requestsById["Combat.Fireball"]

	expect(created.port.sent).toEqual({
		{
			commandId = Constants.START_COMMAND_ID,
			actor = created.actor.view,
			requestId = requestId,
			request = {
				actionId = "Combat.Fireball",
				contractTag = request.contractTag,
				payload = RequestUtils.encode(request.start, { aim = aim }),
			},
		},
	})
end)

it("reserves immutable original Start metadata before the packet leaves", function()
	local created: TestUtils.Fixture = setup()
	local observedDuringSend: Types.ActionRequestAdmission? = nil

	created.port.onSend = function(sent: TestUtils.Sent): ()
		observedDuringSend = created.runtime:GetOriginalStart(sent.requestId)
	end

	local requestId: number = admitStart(created, "Movement.Sprint")

	local expected: Types.ActionRequestAdmission = {
		kind = "Start",
		incarnation = 1,
		requestId = requestId,
		originalStartRequestId = requestId,
		actor = created.actor.view,
		actionId = "Movement.Sprint",
		origin = "Input",
		inputTimestamp = 12.5,
	}

	expect(observedDuringSend).toEqual(expected)
	local retained: Types.ActionRequestAdmission? = created.runtime:GetOriginalStart(requestId)
	expect(retained).toEqual(expected)
	assert(retained ~= nil, "Expected retained original Start metadata")
	expect(table.isfrozen(retained)).toBe(true)
end)

it("notifies admission observers only after the packet has been attempted", function()
	local created: TestUtils.Fixture = setup()

	created.runtime:ObserveAdmissions(function(admission: Types.ActionRequestAdmission): ()
		table.insert(created.port.order, "Admitted:" .. admission.kind .. ":" .. admission.requestId)
	end)

	admitStart(created, "Movement.Sprint")
	expect(created.port.order).toEqual({ "Sent:KRF.Action.Start:1", "Admitted:Start:1" })
end)

type RefusedStart = { label: string, actionId: string, parameters: any?, reason: string }

local refusedStarts: { RefusedStart } = {
	{
		label = "invalid typed parameters",
		actionId = "Combat.Fireball",
		parameters = { aim = { x = "left" } },
		reason = "ActionPayloadInvalid",
	},
	{
		label = "parameters for a parameterless Start",
		actionId = "Movement.Sprint",
		parameters = { speed = 2 },
		reason = "ActionPayloadUnexpected",
	},
	{ label = "an unregistered Action", actionId = "Combat.Unknown", reason = "ActionRequestUnregistered" },
}

for _, refused: RefusedStart in refusedStarts do
	it("refuses " .. refused.label .. " without sending or retaining anything", function()
		local created: TestUtils.Fixture = setup()
		local admissions: number = 0

		created.runtime:ObserveAdmissions(function(): ()
			admissions += 1
		end)

		local requestId: number?, reason: string? =
			created.runtime:Start(TestUtils.selection(created, refused.actionId), refused.parameters)

		expect(requestId).toBeNil()
		expect(reason).toBe(refused.reason)
		expect(created.port.sent).toEqual({})
		expect(admissions).toBe(0)
		expect(created.runtime:_GetRetainedCountForTests()).toBe(0)
	end)
end

it("refuses a Start for an unavailable original ActorView", function()
	local created: TestUtils.Fixture = setup()
	local gone: ActorTypes.ActorViewOwner = TestUtils.view(created, "ActorGone")
	gone:Destroy()

	local requestId: number?, reason: string? =
		created.runtime:Start(TestUtils.selection(created, "Movement.Sprint", gone.view))

	expect(requestId).toBeNil()
	expect(reason).toBe("ActorViewUnavailable")
	expect(created.port.sent).toEqual({})
end)

it("returns nil with the transport reason and rolls back metadata when N9 refuses admission", function()
	local created: TestUtils.Fixture = setup()
	created.port.refusal = "CommandPendingFull"
	local requestId: number?, reason: string? = created.runtime:Start(TestUtils.selection(created, "Movement.Sprint"))
	expect(requestId).toBeNil()
	expect(reason).toBe("CommandPendingFull")
	expect(created.runtime:_GetRetainedCountForTests()).toBe(0)
	expect(created.runtime:GetOriginalStart(1)).toBeNil()
end)

it("admits a typed Stop for the original receipt using the original Action's Stop schema", function()
	local created: TestUtils.Fixture = setup()
	local startId: number = admitStart(created, "Technique.Cast", { techniqueId = "Chidori", aim = aim })
	local stopId: number?, reason: string? = created.runtime:Stop(startId, { releaseAim = aim })
	expect(reason).toBeNil()
	assert(stopId ~= nil, "Expected an admitted Stop")

	local stop: ActionRequestTypes.CompiledActionPayload? = created.catalog.requestsById["Technique.Cast"].stop
	assert(stop ~= nil, "Expected typed Stop parameters")

	expect(created.port.sent[2]).toEqual({
		commandId = Constants.STOP_COMMAND_ID,
		actor = nil,
		requestId = stopId,
		request = { originalStartRequestId = startId, payload = RequestUtils.encode(stop, { releaseAim = aim }) },
	})
end)

it("carries the original Actor and Action on a follow-up after that ActorView became unavailable", function()
	local created: TestUtils.Fixture = setup()
	local mount: ActorTypes.ActorViewOwner = TestUtils.view(created, "Mount")
	local startId: number? = created.runtime:Start(TestUtils.selection(created, "Movement.Sprint", mount.view))
	assert(startId ~= nil, "Expected an admitted Start")
	mount:Destroy()

	local admissions: { Types.ActionRequestAdmission } = {}

	created.runtime:ObserveAdmissions(function(admission: Types.ActionRequestAdmission): ()
		table.insert(admissions, admission)
	end)

	local stopId: number? = created.runtime:Stop(startId)
	assert(stopId ~= nil, "A follow-up must not depend on current ActorView availability")
	expect(admissions[1].kind).toBe("Stop")
	expect(admissions[1].originalStartRequestId).toBe(startId)
	expect(admissions[1].actor).toBe(mount.view)
	expect(admissions[1].actionId).toBe("Movement.Sprint")
end)

type RefusedFollowUp = { label: string, actionId: string, follow: "Stop" | "Interrupt", value: any?, reason: string }

local refusedFollowUps: { RefusedFollowUp } = {
	{
		label = "Stop with no declared Stop path",
		actionId = "Combat.Fireball",
		follow = "Stop",
		reason = "ActionStopUnavailable",
	},
	{
		label = "Stop with invalid typed parameters",
		actionId = "Technique.Cast",
		follow = "Stop",
		value = { releaseAim = "up" },
		reason = "ActionPayloadInvalid",
	},
	{
		label = "Interrupt without input interruption permission",
		actionId = "Combat.Fireball",
		follow = "Interrupt",
		value = "FocusLost",
		reason = "ActionInterruptNotAllowed",
	},
	{
		label = "Interrupt with a reason outside the closed vocabulary",
		actionId = "Movement.Sprint",
		follow = "Interrupt",
		value = "Teleported",
		reason = "ActionInterruptReasonInvalid",
	},
}

for _, refused: RefusedFollowUp in refusedFollowUps do
	it("refuses " .. refused.label .. " before admission", function()
		local created: TestUtils.Fixture = setup()
		local parameters: any? = if refused.actionId == "Combat.Fireball" then { aim = aim } else nil

		if refused.actionId == "Technique.Cast" then
			parameters = { techniqueId = "Chidori", aim = aim }
		end

		local startId: number = admitStart(created, refused.actionId, parameters)
		local requestId: number?, reason: string?

		if refused.follow == "Stop" then
			requestId, reason = created.runtime:Stop(startId, refused.value)
		else
			requestId, reason = created.runtime:Interrupt(startId, refused.value)
		end

		expect(requestId).toBeNil()
		expect(reason).toBe(refused.reason)
		expect(#created.port.sent).toBe(1)
	end)
end

it("sends no phantom follow-up for a Start that was never admitted", function()
	local created: TestUtils.Fixture = setup()
	created.port.refusal = "CommandPendingFull"
	created.runtime:Start(TestUtils.selection(created, "Movement.Sprint"))
	created.port.refusal = nil

	expect({ created.runtime:Stop(1) }).toEqual({ nil, "ActionStartUnknown" })
	expect({ created.runtime:Interrupt(1, "FocusLost") }).toEqual({ nil, "ActionStartUnknown" })
	expect(created.port.sent).toEqual({})
end)

it("admits a permitted Interrupt for the original receipt with its closed reason", function()
	local created: TestUtils.Fixture = setup()
	local startId: number = admitStart(created, "Movement.Sprint")
	local interruptId: number? = created.runtime:Interrupt(startId, "ActorSwitched")
	assert(interruptId ~= nil, "Expected an admitted Interrupt")

	expect(created.port.sent[2]).toEqual({
		commandId = Constants.INTERRUPT_COMMAND_ID,
		actor = nil,
		requestId = interruptId,
		request = { originalStartRequestId = startId, reason = "ActorSwitched" },
	})
end)

it("lets an admission observer request Stop without the Stop overtaking its Start", function()
	local created: TestUtils.Fixture = setup()
	local stopId: number? = nil

	created.runtime:ObserveAdmissions(function(admission: Types.ActionRequestAdmission): ()
		if admission.kind == "Start" then
			stopId = created.runtime:Stop(admission.requestId)
		end
	end)

	local startId: number = admitStart(created, "Movement.Sprint")
	assert(stopId ~= nil, "Expected the reentrant Stop to be admitted")
	expect(stopId > startId).toBe(true)
	expect(created.port.order).toEqual({ "Sent:KRF.Action.Start:1", "Sent:KRF.Action.Stop:2" })
end)

it("isolates a throwing or yielding admission observer from egress and other observers", function()
	local created: TestUtils.Fixture = setup()
	local healthy: number = 0

	created.runtime:ObserveAdmissions(function(): ()
		error("PresentationExploded")
	end)

	created.runtime:ObserveAdmissions(function(): ()
		task.wait()
	end)

	created.runtime:ObserveAdmissions(function(): ()
		healthy += 1
	end)

	admitStart(created, "Movement.Sprint")
	admitStart(created, "Movement.Sprint")
	expect(#created.port.sent).toBe(2)
	expect(healthy).toBe(2)
end)

it("stops notifying a disconnected admission observer", function()
	local created: TestUtils.Fixture = setup()
	local calls: number = 0

	local disconnect: () -> () = created.runtime:ObserveAdmissions(function(): ()
		calls += 1
	end)

	admitStart(created, "Movement.Sprint")
	disconnect()
	disconnect()
	admitStart(created, "Movement.Sprint")
	expect(calls).toBe(1)
end)

it("bounds retained original Starts and refuses new Starts at capacity", function()
	local created: TestUtils.Fixture = setup({ maxOriginalStarts = 2 })
	admitStart(created, "Movement.Sprint")
	admitStart(created, "Movement.Sprint")
	local requestId: number?, reason: string? = created.runtime:Start(TestUtils.selection(created, "Movement.Sprint"))
	expect(requestId).toBeNil()
	expect(reason).toBe("ActionRequestCapacityReached")
	expect(#created.port.sent).toBe(2)
end)

it("refuses every request after destruction", function()
	local created: TestUtils.Fixture = setup()
	local startId: number = admitStart(created, "Movement.Sprint")
	created.runtime:Destroy()

	expect({ created.runtime:Start(TestUtils.selection(created, "Movement.Sprint")) }).toEqual({
		nil,
		"ActionRequestRuntimeDestroyed",
	})

	expect({ created.runtime:Stop(startId) }).toEqual({ nil, "ActionRequestRuntimeDestroyed" })
	expect(created.runtime:GetOriginalStart(startId)).toBeNil()
	expect(created.runtime:_GetRetainedCountForTests()).toBe(0)
end)

it("rolls back Start and follow-up metadata when N9 refuses after the admission callback", function()
	local created: TestUtils.Fixture = setup()
	local startId: number = admitStart(created, "Movement.Sprint")

	created.port.refusalAfterAdmit = "ClientNotReady"
	expect({ created.runtime:Start(TestUtils.selection(created, "Movement.Sprint")) }).toEqual({ nil, "ClientNotReady" })
	expect({ created.runtime:Stop(startId) }).toEqual({ nil, "ClientNotReady" })
	expect(created.runtime:GetOriginalStart(startId + 1)).toBeNil()
	expect(created.runtime:_GetRetainedCountForTests()).toBe(1)
end)

it("refuses Interrupt after destruction", function()
	local created: TestUtils.Fixture = setup()
	local startId: number = admitStart(created, "Movement.Sprint")
	created.runtime:Destroy()
	expect({ created.runtime:Interrupt(startId, "FocusLost") }).toEqual({ nil, "ActionRequestRuntimeDestroyed" })
end)

it("skips an admission observer disconnected by an earlier observer during the same delivery", function()
	local created: TestUtils.Fixture = setup()
	local later: number = 0
	local disconnectLater: () -> () = function(): () end

	created.runtime:ObserveAdmissions(function(): ()
		disconnectLater()
	end)

	disconnectLater = created.runtime:ObserveAdmissions(function(): ()
		later += 1
	end)

	admitStart(created, "Movement.Sprint")
	expect(later).toBe(0)
end)
