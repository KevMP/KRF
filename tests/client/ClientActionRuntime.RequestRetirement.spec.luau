--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local Types = require(KRF.client.Action.types)
local RequestTypes = require(KRF.client.ActionRequest.types)
local Runtime: Types.ClientActionRuntime = require(KRF.client.Action.ClientActionRuntime)
local Requests = require(KRF.client.ActionRequest.utils.ClientActionRequestState)
local State = require(KRF.client.Action.utils.ClientActionRuntimeState)
local Constants = require(KRF.shared.Networking.utils.CommandConstants)
local Utils = require(script.Parent.Utils.ActionInputTestUtils)
local fixture: Utils.Fixture

beforeEach(function()
	fixture = Utils.new()
end)

afterEach(function()
	Utils.destroy(fixture)
end)

local function retire(original: number): (boolean, string?)
	local facade = (Runtime :: unknown) :: { read RetireRequest: (number) -> (boolean, string?) }
	expect(type(facade.RetireRequest)).toBe("function")

	return facade.RetireRequest(original)
end

it("reclaims more than 64 accepted Toggles when default Keep invalidation detaches ownership", function()
	Utils.ready(fixture, Utils.policies())
	local requests: RequestTypes.ClientActionRequestRuntime = assert(Requests.Get())

	for cycle = 1, 80 do
		Utils.set(fixture, { Utils.route("Mode.Aura") })
		Utils.tap(fixture)
		Utils.outcome(fixture, cycle, "KRF.Action.Start", "Accepted")
		expect(requests:_GetRetainedCountForTests()).toBe(1)
		expect({ Runtime.RemoveProfileSource(fixture.actor, "Base") }).toEqual({ true })
		expect(requests:GetOriginalStart(cycle) == nil).toBe(true)
		expect(requests:_GetRetainedCountForTests()).toBe(0)
	end

	expect(#Utils.packets(fixture)).toBe(80)
end)

it("reclaims direct originals across more than 64 Accepted Interrupt cycles", function()
	Utils.ready(fixture, Utils.policies())
	local requests: RequestTypes.ClientActionRequestRuntime = assert(Requests.Get())

	for _ = 1, 80 do
		local original: number = assert(Runtime.RequestAction(fixture.actor, "Mode.Aura"))
		Utils.outcome(fixture, original, "KRF.Action.Start", "Accepted")
		local interrupted: number = assert(Runtime.RequestInterrupt(original, "FocusLost"))
		Utils.outcome(fixture, interrupted, "KRF.Action.Interrupt", "Accepted")
		expect(requests:GetOriginalStart(original) == nil).toBe(true)
		expect(requests:_GetRetainedCountForTests()).toBe(0)
	end

	expect(#Utils.packets(fixture)).toBe(160)
end)

it("retires an Accepted Interrupt before Start acknowledgement without losing the later Start outcome", function()
	Utils.ready(fixture, Utils.policies())
	local requests: RequestTypes.ClientActionRequestRuntime = assert(Requests.Get())
	local kinds: { string } = {}

	requests:ObserveOutcomes(function(outcome): ()
		table.insert(kinds, outcome.admission.kind)
	end)

	local original: number = assert(Runtime.RequestAction(fixture.actor, "Mode.Aura"))
	local interrupted: number = assert(Runtime.RequestInterrupt(original, "FocusLost"))
	Utils.outcome(fixture, interrupted, "KRF.Action.Interrupt", "Accepted")
	expect(requests:GetOriginalStart(original) == nil).toBe(true)
	expect(requests:_GetRetainedCountForTests()).toBe(1)
	Utils.outcome(fixture, original, "KRF.Action.Start", "Accepted")
	expect(kinds).toEqual({ "Interrupt", "Start" })
	expect(requests:_GetRetainedCountForTests()).toBe(0)
end)

it("reconciles an Unknown Interrupt with a late Accepted terminal result during grace", function()
	Utils.ready(fixture, Utils.policies())
	local requests: RequestTypes.ClientActionRequestRuntime = assert(Requests.Get())
	local original: number = assert(Runtime.RequestAction(fixture.actor, "Mode.Aura"))
	Utils.outcome(fixture, original, "KRF.Action.Start", "Accepted")
	local interrupted: number = assert(Runtime.RequestInterrupt(original, "FocusLost"))
	local statuses: { string } = {}

	requests:ObserveOutcomes(function(outcome): ()
		table.insert(statuses, outcome.status)
	end)

	fixture.clock.Advance(Constants.TIMEOUT_SECONDS)
	expect(requests:GetOriginalStart(original) ~= nil).toBe(true)
	Utils.outcome(fixture, interrupted, "KRF.Action.Interrupt", "Accepted")
	expect(statuses).toEqual({ "Unknown", "Accepted" })
	expect(requests:_GetRetainedCountForTests()).toBe(0)
	expect(#Utils.packets(fixture)).toBe(2)
end)

it("keeps authority for Rejected Interrupts and for Unknown Interrupts after grace expires", function()
	Utils.ready(fixture, Utils.policies())
	local requests: RequestTypes.ClientActionRequestRuntime = assert(Requests.Get())
	local original: number = assert(Runtime.RequestAction(fixture.actor, "Mode.Aura"))
	Utils.outcome(fixture, original, "KRF.Action.Start", "Accepted")
	local rejected: number = assert(Runtime.RequestInterrupt(original, "FocusLost"))
	Utils.outcome(fixture, rejected, "KRF.Action.Interrupt", "Rejected", "GameDenied")
	expect(requests:GetOriginalStart(original) ~= nil).toBe(true)
	Runtime.RequestInterrupt(original, "FocusLost")
	fixture.clock.Advance(Constants.TIMEOUT_SECONDS + Constants.GRACE_SECONDS)
	expect(requests:GetOriginalStart(original) ~= nil).toBe(true)
	expect(requests:_GetRetainedCountForTests()).toBe(1)
	expect(#Utils.packets(fixture)).toBe(3)
end)

it("leaves Accepted Stop nonterminal and explicitly retires local authority across repeated direct cycles", function()
	Utils.ready(fixture, Utils.policies())
	local requests: RequestTypes.ClientActionRequestRuntime = assert(Requests.Get())

	for _ = 1, 80 do
		local original: number = assert(Runtime.RequestAction(fixture.actor, "Mode.Aura"))
		Utils.outcome(fixture, original, "KRF.Action.Start", "Accepted")
		local stopped: number = assert(Runtime.RequestStop(original))
		Utils.outcome(fixture, stopped, "KRF.Action.Stop", "Accepted")
		expect(requests:GetOriginalStart(original) ~= nil).toBe(true)
		expect({ retire(original) }).toEqual({ true })
		expect(requests:_GetRetainedCountForTests()).toBe(0)
		expect({ retire(original) }).toEqual({ false, "ActionStartUnknown" })
	end

	expect(#Utils.packets(fixture)).toBe(160)
end)

it("locally retires a pending automatic request without sending or manufacturing a release", function()
	Utils.ready(fixture, Utils.policies())
	local requests: RequestTypes.ClientActionRequestRuntime = assert(Requests.Get())
	local decisions: { string } = {}

	assert(State.GetInput()).ObserveDecisions(function(fact): ()
		table.insert(decisions, fact.kind)
	end)

	Utils.set(fixture, { Utils.route("Combat.Rasengan") })
	Utils.emit(fixture, "Pressed")
	expect({ retire(1) }).toEqual({ true })
	Utils.emit(fixture, "Released")
	expect(decisions).toEqual({})
	expect(#Utils.packets(fixture)).toBe(1)
	expect(requests:_GetRetainedCountForTests()).toBe(1)
	Utils.outcome(fixture, 1, "KRF.Action.Start", "Accepted")
	expect(requests:_GetRetainedCountForTests()).toBe(0)
end)

it("rejects retirement before readiness, for unknown ids and during input mutation", function()
	expect({ retire(1) }).toEqual({ false, "ClientNotReady" })
	local nested: { any } = {}

	local policies: Types.ActionInputPolicies = Utils.policies()

	policies["Mode.Aura"].startParameters = function(): any
		nested = { retire(1) }

		return nil
	end

	Utils.ready(fixture, policies)
	expect({ retire(999) }).toEqual({ false, "ActionStartUnknown" })
	Runtime.RequestAction(fixture.actor, "Mode.Aura")
	Utils.set(fixture, { Utils.route("Mode.Aura") })
	Utils.tap(fixture)
	expect(nested).toEqual({ false, "DispatchInProgress" })
	expect(assert(Requests.Get()):GetOriginalStart(1) ~= nil).toBe(true)
end)
