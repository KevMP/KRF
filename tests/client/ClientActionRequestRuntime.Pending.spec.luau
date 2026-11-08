--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local afterEach: any = JestGlobals.afterEach
local Types = require(KRF.client.ActionRequest.types)
local Constants = require(KRF.shared.ActionRequest.utils.ActionRequestConstants)
local Payload = require(KRF.shared.ActionRequest.utils.ActionPayloadCodec)
local Utils = require(script.Parent.Utils.ActionRequestClientTestUtils)
local fixture: Utils.Fixture?

afterEach(function()
	Utils.destroy(fixture)
	fixture = nil
end)

local function setup(actionId: string?): (Utils.Fixture, number)
	local created: Utils.Fixture = Utils.new()
	fixture = created

	local original: number = assert(
		created.runtime:Start(
			Utils.selection(created, actionId or "Movement.Sprint"),
			if actionId == "Technique.Cast" then { techniqueId = "Charge", aim = { x = 1, y = 0, z = 0 } } else nil
		)
	)

	return created, original
end

it("keeps one owned Stop byte snapshot through repeated capacity refusals", function()
	local created: Utils.Fixture, original: number = setup("Technique.Cast")
	local parameters = { releaseAim = { x = 1, y = 2, z = 3 } }

	created.port.refusal = "CommandPendingFull"
	expect({ created.runtime:Stop(original, parameters, true) }).toEqual({ nil, "CommandPendingFull" })
	parameters.releaseAim.x = 9
	Utils.resumeCapacity(created)
	Utils.resumeCapacity(created)
	expect(#created.port.sent).toBe(1)
	created.port.refusal = nil
	Utils.resumeCapacity(created)
	expect(#created.port.sent).toBe(2)
	local payload: string = created.port.sent[2].request.payload

	local valid: boolean, value: any = Payload.Decode(
		assert(created.catalog.requestsById["Technique.Cast"].stop, "Expected typed Stop contract"),
		payload
	)

	expect(valid).toBe(true)
	expect(value.releaseAim).toEqual({ x = 1, y = 2, z = 3 })
	Utils.resumeCapacity(created)
	expect(#created.port.sent).toBe(2)
end)

it("coalesces pending Stop and preserves a newer terminal invalidation over later Stops", function()
	local created: Utils.Fixture, original: number = setup()
	created.port.refusal = "CommandPendingFull"
	created.runtime:Stop(original, nil, true)
	created.runtime:Stop(original, nil, true)
	created.runtime:Interrupt(original, "FocusLost", true)
	created.runtime:Stop(original, nil, true)
	created.port.refusal = nil
	Utils.resumeCapacity(created)
	expect(#created.port.sent).toBe(2)

	expect(created.port.sent[2]).toMatchObject({
		commandId = Constants.INTERRUPT_COMMAND_ID,
		request = { originalStartRequestId = original, reason = "FocusLost" },
	})
end)

it("does not erase a newer invalidation queued reentrantly while draining Stop", function()
	local created: Utils.Fixture, original: number = setup()
	created.port.refusal = "ClientNotReady"
	created.runtime:Stop(original, nil, true)
	created.port.refusal = nil

	created.port.onSend = function(): ()
		created.port.onSend = nil
		created.port.refusal = "CommandPendingFull"
		created.runtime:Interrupt(original, "ActorSwitched", true)
		Utils.resumeCapacity(created)
	end

	Utils.resumeCapacity(created)
	created.port.refusal = nil
	Utils.resumeCapacity(created)
	expect(#created.port.sent).toBe(3)
	expect(created.port.sent[3].commandId).toBe(Constants.INTERRUPT_COMMAND_ID)
	Utils.resumeCapacity(created)
	expect(#created.port.sent).toBe(3)
end)

it("drops pending follow-ups on retirement and connection teardown", function()
	local created: Utils.Fixture, original: number = setup()
	created.port.refusal = "CommandPendingFull"
	created.runtime:Stop(original, nil, true)
	created.runtime:Retire(original)
	created.port.refusal = nil
	Utils.resumeCapacity(created)
	expect(#created.port.sent).toBe(1)
	expect({ created.runtime:Interrupt(original, "FocusLost") }).toEqual({ nil, "ActionStartUnknown" })
	local nextOriginal: number = assert(created.runtime:Start(Utils.selection(created, "Movement.Sprint")))

	created.port.refusal = "CommandPendingFull"
	created.runtime:Stop(nextOriginal, nil, true)
	created.runtime:Destroy()
	created.port.refusal = nil
	Utils.resumeCapacity(created)
	expect(#created.port.sent).toBe(2)
	expect(created.port.capacityObservers).toEqual({})

	local disconnect = created.runtime:ObserveOutcomes(function(): ()
		error("Stale observer ran")
	end)

	disconnect()
end)

it("keeps retired Start correlation until its late definitive result without restoring authority", function()
	local created: Utils.Fixture, original: number = setup()
	local admission: Types.ActionRequestAdmission = assert(created.runtime:GetOriginalStart(original))
	local outcomes: { Types.ActionRequestOutcome } = {}

	created.runtime:ObserveOutcomes(function(outcome): ()
		table.insert(outcomes, outcome)
	end)

	created.runtime:Retire(original)
	expect(created.runtime:GetOriginalStart(original)).toBeNil()
	Utils.deliver(created, original, Constants.START_COMMAND_ID, "Unknown", nil, "CommandTimeout")
	Utils.deliver(created, original, Constants.START_COMMAND_ID, "Accepted", { sequenceId = 12 })
	expect(outcomes[2]).toEqual({ admission = admission, status = "Accepted", sequenceId = 12 })
	expect(created.runtime:_GetRetainedCountForTests()).toBe(0)
	expect({ created.runtime:Stop(original) }).toEqual({ nil, "ActionStartUnknown" })
end)

it("never requeues an admitted Unknown Stop when capacity returns", function()
	local created: Utils.Fixture, original: number = setup()
	created.port.refusal = "CommandPendingFull"
	created.runtime:Stop(original, nil, true)
	created.port.refusal = nil
	Utils.resumeCapacity(created)
	Utils.deliver(created, 2, Constants.STOP_COMMAND_ID, "Unknown", nil, "CommandTimeout")
	Utils.resumeCapacity(created)
	expect(#created.port.sent).toBe(2)
end)

it("runs final admission bookkeeping before follow-up egress and retains its result", function()
	local created: Utils.Fixture, original: number = setup()
	local order: { string } = {}

	created.port.onSend = function(): ()
		table.insert(order, "Egress")
		expect(created.runtime:GetOriginalStart(original)).toBeNil()
	end

	created.runtime:ObserveAdmissions(function(admission): ()
		table.insert(order, "Admission:" .. admission.kind)
	end)

	created.port.refusal = "CommandPendingFull"

	created.runtime:Stop(original, nil, true, function(): ()
		table.insert(order, "Committed")
		created.runtime:Retire(original)
	end)

	created.port.refusal = nil
	Utils.resumeCapacity(created)
	expect(order).toEqual({ "Committed", "Egress", "Admission:Stop" })
end)

for _, yields: boolean in { false, true } do
	it(
		"withdraws provisional correlation when its reservation callback " .. (if yields then "yields" else "throws"),
		function()
			local created: Utils.Fixture = Utils.new()
			fixture = created

			local selected: Types.ActionStartSelection = {
				actor = created.actor.view,
				actionId = "Movement.Sprint",
				origin = "Input",
				Reserve = function(): ()
					if yields then
						coroutine.yield()
					else
						error("Reservation failed")
					end
				end,
			}

			expect({ created.runtime:Start(selected) }).toEqual({ nil, "CommandAdmissionRefused" })
			expect(created.runtime:_GetRetainedCountForTests()).toBe(0)
			expect(created.port.sent).toEqual({})
		end
	)
end

it("bounds unresolved follow-ups independently and drains one intent when a result frees capacity", function()
	local created: Utils.Fixture = Utils.new(nil, { maxOriginalStarts = 1 })
	fixture = created
	local original: number = assert(created.runtime:Start(Utils.selection(created, "Movement.Sprint")))
	expect({ created.runtime:Stop(original) }).toEqual({ 2 })
	expect({ created.runtime:Stop(original) }).toEqual({ 3 })
	expect({ created.runtime:Stop(original, nil, true) }).toEqual({ nil, "ActionRequestCapacityReached" })
	Utils.deliver(created, 2, Constants.STOP_COMMAND_ID, "Accepted")
	Utils.resumeCapacity(created)
	expect(#created.port.sent).toBe(4)
	Utils.resumeCapacity(created)
	expect(#created.port.sent).toBe(4)
end)
