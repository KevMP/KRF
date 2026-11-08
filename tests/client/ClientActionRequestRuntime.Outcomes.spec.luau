--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local afterEach: any = JestGlobals.afterEach
local Types = require(KRF.client.ActionRequest.types)
local ActorTypes = require(KRF.client.Actor.types)
local Constants = require(KRF.shared.ActionRequest.utils.ActionRequestConstants)
local TestUtils = require(script.Parent.Utils.ActionRequestClientTestUtils)

local fixture: TestUtils.Fixture? = nil

afterEach(function()
	TestUtils.destroy(fixture)
	fixture = nil
end)

type Setup = { fixture: TestUtils.Fixture, outcomes: { Types.ActionRequestOutcome } }

local function setup(): Setup
	local created: TestUtils.Fixture = TestUtils.new()
	fixture = created
	local outcomes: { Types.ActionRequestOutcome } = {}

	created.runtime:ObserveOutcomes(function(outcome: Types.ActionRequestOutcome): ()
		table.insert(outcomes, outcome)
	end)

	return { fixture = created, outcomes = outcomes }
end

local function admitStart(
	created: TestUtils.Fixture,
	actionId: string,
	actor: ActorTypes.ActorView?,
	parameters: any?
): number
	local requestId: number?, reason: string? =
		created.runtime:Start(TestUtils.selection(created, actionId, actor), parameters)

	expect(reason).toBeNil()
	assert(requestId ~= nil, "Expected a locally admitted Start")

	return requestId
end

it("correlates an Accepted Start with its original metadata and the real server sequence id", function()
	local state: Setup = setup()
	local startId: number = admitStart(state.fixture, "Movement.Sprint")
	TestUtils.deliver(state.fixture, startId, Constants.START_COMMAND_ID, "Accepted", { sequenceId = 77 })

	expect(#state.outcomes).toBe(1)
	local outcome: Types.ActionRequestOutcome = state.outcomes[1]
	expect(outcome.status).toBe("Accepted")
	expect(outcome.sequenceId).toBe(77)
	expect(outcome.reason).toBeNil()
	expect(outcome.admission).toEqual(state.fixture.runtime:GetOriginalStart(startId))
	expect(table.isfrozen(outcome)).toBe(true)
end)

it("retires the original Start on a definitive rejection so no follow-up can be sent", function()
	local state: Setup = setup()
	local startId: number = admitStart(state.fixture, "Movement.Sprint")
	TestUtils.deliver(state.fixture, startId, Constants.START_COMMAND_ID, "Rejected", nil, "ActionNotGranted")

	expect(state.outcomes[1].status).toBe("Rejected")
	expect(state.outcomes[1].reason).toBe("ActionNotGranted")
	expect(state.outcomes[1].sequenceId).toBeNil()
	expect(state.fixture.runtime:GetOriginalStart(startId)).toBeNil()
	expect({ state.fixture.runtime:Stop(startId) }).toEqual({ nil, "ActionStartUnknown" })
	expect(state.fixture.runtime:_GetRetainedCountForTests()).toBe(0)
end)

it("keeps follow-up authority for an Unknown Start and reconciles a later definitive result", function()
	local state: Setup = setup()
	local startId: number = admitStart(state.fixture, "Movement.Sprint")
	TestUtils.deliver(state.fixture, startId, Constants.START_COMMAND_ID, "Unknown", nil, "CommandTimeout")
	expect(state.outcomes[1].status).toBe("Unknown")
	expect(state.fixture.runtime:GetOriginalStart(startId)).never.toBeNil()

	local stopId: number? = state.fixture.runtime:Stop(startId)
	expect(stopId).never.toBeNil()

	TestUtils.deliver(state.fixture, startId, Constants.START_COMMAND_ID, "Accepted", { sequenceId = 5 })
	expect(state.outcomes[2].status).toBe("Accepted")
	expect(state.outcomes[2].sequenceId).toBe(5)
	expect(state.outcomes[2].admission.requestId).toBe(startId)
end)

it("drops a release-free Action's original Start once it is definitively accepted", function()
	local state: Setup = setup()
	local startId: number = admitStart(state.fixture, "Combat.Fireball", nil, { aim = { x = 0, y = 0, z = 0 } })
	TestUtils.deliver(state.fixture, startId, Constants.START_COMMAND_ID, "Accepted", { sequenceId = 3 })
	expect(state.outcomes[1].admission.actionId).toBe("Combat.Fireball")
	expect(state.fixture.runtime:GetOriginalStart(startId)).toBeNil()
	expect(state.fixture.runtime:_GetRetainedCountForTests()).toBe(0)
end)

it("retains a follow-up-capable original Start after acceptance until I6 retires it", function()
	local state: Setup = setup()
	local startId: number = admitStart(state.fixture, "Movement.Sprint")
	TestUtils.deliver(state.fixture, startId, Constants.START_COMMAND_ID, "Accepted", { sequenceId = 3 })
	expect(state.fixture.runtime:GetOriginalStart(startId)).never.toBeNil()
	state.fixture.runtime:Retire(startId)
	state.fixture.runtime:Retire(startId)
	expect(state.fixture.runtime:GetOriginalStart(startId)).toBeNil()
	expect(state.fixture.runtime:_GetRetainedCountForTests()).toBe(0)
end)

it("keeps pending correlation for an admitted Stop after its activation is retired", function()
	local state: Setup = setup()
	local startId: number = admitStart(state.fixture, "Movement.Sprint")
	local stopId: number? = state.fixture.runtime:Stop(startId)
	assert(stopId ~= nil, "Expected an admitted Stop")
	state.fixture.runtime:Retire(startId)
	TestUtils.deliver(state.fixture, stopId, Constants.STOP_COMMAND_ID, "Accepted")

	local outcome: Types.ActionRequestOutcome = state.outcomes[1]
	expect(outcome.admission.kind).toBe("Stop")
	expect(outcome.admission.originalStartRequestId).toBe(startId)
	expect(outcome.admission.actionId).toBe("Movement.Sprint")
	expect(outcome.sequenceId).toBeNil()
end)

it("reports a follow-up outcome with its original Actor after that ActorView became unavailable", function()
	local state: Setup = setup()
	local mount: ActorTypes.ActorViewOwner = TestUtils.view(state.fixture, "Mount")
	local startId: number = admitStart(state.fixture, "Movement.Sprint", mount.view)
	local interruptId: number? = state.fixture.runtime:Interrupt(startId, "ActorSwitched")
	assert(interruptId ~= nil, "Expected an admitted Interrupt")
	mount:Destroy()

	TestUtils.deliver(
		state.fixture,
		interruptId,
		Constants.INTERRUPT_COMMAND_ID,
		"Rejected",
		nil,
		"ActionReceiptUnknown"
	)

	expect(state.outcomes[1].admission.actor).toBe(mount.view)
	expect(state.outcomes[1].admission.kind).toBe("Interrupt")
end)

it("ignores results for unrelated commands and unknown request ids", function()
	local state: Setup = setup()
	local startId: number = admitStart(state.fixture, "Movement.Sprint")
	TestUtils.deliver(state.fixture, startId, "Game.Ping", "Accepted")
	TestUtils.deliver(state.fixture, startId + 10, Constants.START_COMMAND_ID, "Accepted", { sequenceId = 1 })
	expect(state.outcomes).toEqual({})
end)

it("never auto-retries or interrupts an admitted Stop that becomes Unknown", function()
	local state: Setup = setup()
	local startId: number = admitStart(state.fixture, "Movement.Sprint")
	local stopId: number? = state.fixture.runtime:Stop(startId)
	assert(stopId ~= nil, "Expected an admitted Stop")
	TestUtils.deliver(state.fixture, stopId, Constants.STOP_COMMAND_ID, "Unknown", nil, "CommandTimeout")
	expect(#state.fixture.port.sent).toBe(2)
	expect(state.outcomes[1].status).toBe("Unknown")
end)

it("isolates a throwing outcome observer from correlation and other observers", function()
	local state: Setup = setup()

	state.fixture.runtime:ObserveOutcomes(function(): ()
		error("PresentationExploded")
	end)

	local startId: number = admitStart(state.fixture, "Movement.Sprint")
	TestUtils.deliver(state.fixture, startId, Constants.START_COMMAND_ID, "Accepted", { sequenceId = 9 })
	expect(#state.outcomes).toBe(1)
	expect(state.fixture.runtime:GetOriginalStart(startId)).never.toBeNil()
end)

it("reports Unknown for unresolved requests on connection close and then discards every record", function()
	local state: Setup = setup()
	local startId: number = admitStart(state.fixture, "Movement.Sprint")
	TestUtils.deliver(state.fixture, startId, Constants.START_COMMAND_ID, "Unknown", nil, "CommandConnectionClosed")
	expect(state.outcomes[1].status).toBe("Unknown")
	state.fixture.runtime:Destroy()
	expect(state.fixture.runtime:_GetRetainedCountForTests()).toBe(0)
	TestUtils.deliver(state.fixture, startId, Constants.START_COMMAND_ID, "Accepted", { sequenceId = 2 })
	expect(#state.outcomes).toBe(1)
end)

it("reports an Accepted Start without a result payload with no sequence id", function()
	local state: Setup = setup()
	local startId: number = admitStart(state.fixture, "Movement.Sprint")
	TestUtils.deliver(state.fixture, startId, Constants.START_COMMAND_ID, "Accepted")
	expect(state.outcomes[1].status).toBe("Accepted")
	expect(state.outcomes[1].sequenceId).toBeNil()
end)

it("ignores a follow-up result that names a different fixed command", function()
	local state: Setup = setup()
	local startId: number = admitStart(state.fixture, "Movement.Sprint")
	local stopId: number? = state.fixture.runtime:Stop(startId)
	assert(stopId ~= nil, "Expected an admitted Stop")
	TestUtils.deliver(state.fixture, stopId, Constants.INTERRUPT_COMMAND_ID, "Accepted")
	expect(state.outcomes).toEqual({})
	TestUtils.deliver(state.fixture, stopId, Constants.STOP_COMMAND_ID, "Accepted")
	expect(state.outcomes[1].admission.kind).toBe("Stop")
end)

it("publishes Admission before an Outcome the transport delivered while sending", function()
	local created: TestUtils.Fixture = TestUtils.new()
	fixture = created
	local facts: { string } = {}

	created.runtime:ObserveAdmissions(function(admission: Types.ActionRequestAdmission): ()
		table.insert(facts, "Admission:" .. admission.kind .. ":" .. admission.requestId)
	end)

	created.runtime:ObserveOutcomes(function(outcome: Types.ActionRequestOutcome): ()
		table.insert(facts, "Outcome:" .. outcome.admission.kind .. ":" .. outcome.status)
	end)

	-- The send adapter answers synchronously before SendAdmitted returns.
	created.port.onSend = function(sent: TestUtils.Sent): ()
		TestUtils.deliver(created, sent.requestId, sent.commandId, "Accepted", { sequenceId = 9 })
	end

	admitStart(created, "Movement.Sprint")
	expect(facts).toEqual({ "Admission:Start:1", "Outcome:Start:Accepted" })

	-- Correlation was installed immediately; only the observation waited.
	expect(created.runtime:GetOriginalStart(1)).never.toBeNil()
end)

it("keeps causal order when a reentrant transport admits another request mid-send", function()
	local created: TestUtils.Fixture = TestUtils.new()
	fixture = created
	local facts: { string } = {}
	local reentered: boolean = false

	created.runtime:ObserveAdmissions(function(admission: Types.ActionRequestAdmission): ()
		table.insert(facts, "Admission:" .. admission.kind .. ":" .. admission.requestId)
	end)

	created.runtime:ObserveOutcomes(function(outcome: Types.ActionRequestOutcome): ()
		table.insert(facts, "Outcome:" .. outcome.admission.kind .. ":" .. outcome.admission.requestId)
	end)

	created.port.onSend = function(sent: TestUtils.Sent): ()
		TestUtils.deliver(created, sent.requestId, sent.commandId, "Unknown", nil, "CommandTimeout")

		if not reentered then
			reentered = true
			created.runtime:Stop(sent.requestId, nil)
		end
	end

	admitStart(created, "Movement.Sprint")

	expect(facts).toEqual({
		"Admission:Start:1",
		"Outcome:Start:1",
		"Admission:Stop:2",
		"Outcome:Stop:2",
	})
end)

it("withdraws a refused reentrant follow-up without holding back the Start's facts", function()
	local created: TestUtils.Fixture = TestUtils.new()
	fixture = created
	local facts: { string } = {}

	created.runtime:ObserveAdmissions(function(admission: Types.ActionRequestAdmission): ()
		table.insert(facts, "Admission:" .. admission.kind)
	end)

	created.runtime:ObserveOutcomes(function(outcome: Types.ActionRequestOutcome): ()
		table.insert(facts, "Outcome:" .. outcome.admission.kind .. ":" .. outcome.status)
	end)

	created.port.onSend = function(sent: TestUtils.Sent): ()
		created.port.onSend = nil
		created.port.refusalAfterAdmit = "ClientNotReady"
		local stop: number?, reason: string? = created.runtime:Stop(sent.requestId, nil)
		expect(stop).toBeNil()
		expect(reason).toBe("ClientNotReady")
		created.port.refusalAfterAdmit = nil
		TestUtils.deliver(created, sent.requestId, sent.commandId, "Accepted", { sequenceId = 4 })
	end

	admitStart(created, "Movement.Sprint")
	expect(facts).toEqual({ "Admission:Start", "Outcome:Start:Accepted" })
	expect(created.runtime:_GetRetainedCountForTests()).toBe(1)
end)

it("bounds framework observers of each fact stream", function()
	local created: TestUtils.Fixture = TestUtils.new()
	fixture = created

	for _ = 1, 16 do
		created.runtime:ObserveAdmissions(function(): () end)
		created.runtime:ObserveOutcomes(function(): () end)
	end

	expect(function()
		created.runtime:ObserveAdmissions(function(): () end)
	end).toThrow("ActionRequestObserverLimitExceeded")

	expect(function()
		created.runtime:ObserveOutcomes(function(): () end)
	end).toThrow("ActionRequestObserverLimitExceeded")
end)

it("frees an observer slot when that observer disconnects and keeps late observers inert", function()
	local created: TestUtils.Fixture = TestUtils.new()
	fixture = created
	local disconnects: { () -> () } = {}

	for _ = 1, 16 do
		table.insert(disconnects, created.runtime:ObserveOutcomes(function(): () end))
	end

	disconnects[1]()
	disconnects[1]()
	created.runtime:ObserveOutcomes(function(): () end)
	created.runtime:Destroy()

	local disconnect: () -> () = created.runtime:ObserveAdmissions(function(): () end)
	disconnect()
end)
