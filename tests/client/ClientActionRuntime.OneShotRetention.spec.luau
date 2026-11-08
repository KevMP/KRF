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
local State = require(KRF.client.Action.utils.ClientActionRuntimeState)
local Requests = require(KRF.client.ActionRequest.utils.ClientActionRequestState)
local Constants = require(KRF.shared.Networking.utils.CommandConstants)
local Utils = require(script.Parent.Utils.ActionInputTestUtils)
local fixture: Utils.Fixture

beforeEach(function()
	fixture = Utils.new()
end)

afterEach(function()
	Utils.destroy(fixture)
end)

local function ready(explicit: boolean): RequestTypes.ClientActionRequestRuntime
	local policies: Types.ActionInputPolicies? = if explicit
		then { ["Mode.Aura"] = { activation = "OneShot" } }
		else nil

	Utils.ready(fixture, policies, { ["Mode.Aura"] = { stop = {}, allowInputInterrupt = true } })
	Utils.set(fixture, { Utils.route("Mode.Aura") })

	return assert(Requests.Get())
end

for _, explicit: boolean in { false, true } do
	it(
		"reclaims more than 64 accepted "
			.. (if explicit then "explicit" else "default")
			.. " OneShots with Stop and Interrupt schemas",
		function()
			local requests: RequestTypes.ClientActionRequestRuntime = ready(explicit)
			local ids: { number } = {}

			requests:ObserveOutcomes(function(outcome): ()
				if outcome.status == "Accepted" then
					table.insert(ids, outcome.admission.requestId)
				end
			end)

			for cycle = 1, 80 do
				Utils.tap(fixture)
				-- Authority ends on local admission; unresolved outcome metadata survives.
				expect(requests:GetOriginalStart(cycle) == nil).toBe(true)
				expect(requests:_GetRetainedCountForTests()).toBe(1)
				expect(assert(State.GetInput()).Guard.HasActive()).toBe(false)
				Utils.outcome(fixture, cycle, "KRF.Action.Start", "Accepted")
				expect(requests:_GetRetainedCountForTests()).toBe(0)
				expect(ids[cycle]).toBe(cycle)
			end

			expect(#ids).toBe(80)
			expect(#Utils.packets(fixture)).toBe(80)
		end
	)
end

for _, status: "Accepted" | "Rejected" in { "Accepted", "Rejected" } do
	it("preserves a retired OneShot's Unknown to late " .. status .. " correlation", function()
		local requests: RequestTypes.ClientActionRequestRuntime = ready(true)
		local admission: RequestTypes.ActionRequestAdmission?
		local outcomes: { RequestTypes.ActionRequestOutcome } = {}

		requests:ObserveAdmissions(function(value): ()
			admission = value
		end)

		requests:ObserveOutcomes(function(value): ()
			table.insert(outcomes, value)
		end)

		Utils.tap(fixture)
		expect(requests:GetOriginalStart(1) == nil).toBe(true)
		expect({ Runtime.RequestStop(1) }).toEqual({ nil, "ActionStartUnknown" })
		expect({ Runtime.RequestInterrupt(1, "FocusLost") }).toEqual({ nil, "ActionStartUnknown" })
		fixture.clock.Advance(Constants.TIMEOUT_SECONDS)
		expect(outcomes[1].status).toBe("Unknown")
		expect(requests:_GetRetainedCountForTests()).toBe(1)
		Utils.outcome(fixture, 1, "KRF.Action.Start", status, if status == "Rejected" then "ActionNotGranted" else nil)
		expect(#outcomes).toBe(2)
		expect(outcomes[2].status).toBe(status)
		expect(outcomes[2].admission).toBe(admission)
		expect(requests:_GetRetainedCountForTests()).toBe(0)
		expect(#Utils.packets(fixture)).toBe(1)
	end)
end

it("preserves explicit direct-request follow-ups independently of a OneShot input policy", function()
	local requests: RequestTypes.ClientActionRequestRuntime = ready(true)
	local original: number = assert(Runtime.RequestAction(fixture.actor, "Mode.Aura"))
	Utils.outcome(fixture, original, "KRF.Action.Start", "Accepted")
	expect(requests:GetOriginalStart(original) ~= nil).toBe(true)
	expect({ Runtime.RequestStop(original) }).toEqual({ 2 })
	expect(Utils.packets(fixture)[2]).toMatchObject({ kind = "KRF.Action.Stop", originalStartRequestId = original })
end)
