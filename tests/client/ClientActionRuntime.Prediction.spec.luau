--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local afterEach: any = JestGlobals.afterEach
local ActionTypes = require(KRF.client.Action.types)
local Types = require(KRF.client.Presentation.types)
local Events = require(KRF.client.Presentation.PresentationEvents)
local States = require(KRF.client.Presentation.PresentationStates)
local Runtime: ActionTypes.ClientActionRuntime = require(KRF.client.Action.ClientActionRuntime)
local Input = require(script.Parent.Utils.ActionInputTestUtils)
local Observations = require(script.Parent.Utils.ActionObservationTestUtils)
local fixture: Input.Fixture? = nil

afterEach(function()
	Input.destroy(fixture)
	fixture = nil
end)

type Recorded = {
	contexts: { Types.PresentationContext },
	snapshots: { Types.LocalPredictionSnapshot },
	checks: { Types.ActionPredictionCheckContext },
	sentAtCheck: { number },
}

local function ready(actionId: string, decision: boolean?): (Input.Fixture, Recorded)
	local created: Input.Fixture = Input.new()
	fixture = created
	local recorded: Recorded = { contexts = {}, snapshots = {}, checks = {}, sentAtCheck = {} }

	Input.ready(created, Input.policies(), nil, {
		actionPredictionPolicies = {
			[actionId] = {
				canPredictStart = function(context: Types.ActionPredictionCheckContext): boolean?
					table.insert(recorded.checks, context)
					table.insert(recorded.sentAtCheck, #created.commands.sent)

					return if decision == nil then true else decision
				end,
			},
		},
		presentations = {
			{
				id = "Cast",
				entry = { event = Events.Action.Started, id = actionId },
				predict = true,
				create = function(context: Types.PresentationContext)
					table.insert(recorded.contexts, context)

					context:Watch(States.Action.LocalPrediction, function(snapshot: Types.LocalPredictionSnapshot)
						table.insert(recorded.snapshots, snapshot)
					end)
				end,
			},
		},
	})

	return created, recorded
end

it(
	"sends the Start before any authored prediction code and creates the instance after egress without a reply",
	function()
		local created: Input.Fixture, recorded: Recorded = ready("Combat.Fireball")
		local parameters: any = { aim = 4 }

		assert(Runtime.RequestAction(created.actor, "Combat.Fireball", parameters))
		parameters.aim = 99
		expect(#created.commands.sent).toBe(1)
		expect(#recorded.checks).toBe(0)
		expect(#recorded.contexts).toBe(0)
		task.wait()

		expect(recorded.sentAtCheck).toEqual({ 1 })
		expect(#recorded.contexts).toBe(1)
		local sent: Input.Packet = Input.packets(created)[1]
		expect(recorded.checks[1].parameters).toEqual(sent.parameters)
		expect(recorded.checks[1].actor).toBe(created.actor)
		local entry: Types.PresentationEntry = recorded.contexts[1].entry
		assert(entry.source == "ActionPrediction", "Expected a predicted Action entry")
		expect(entry.parameters).toEqual({ aim = 4 })
		expect(entry.originalStartKey).toBe(recorded.checks[1].originalStartKey)
		expect(recorded.snapshots).toEqual({ { startStatus = "Admitted", inputTransitions = {} } })
	end
)

it("keeps sending a locally blocked Start and skips only the cosmetic preview", function()
	local created: Input.Fixture, recorded: Recorded = ready("Combat.Fireball", false)

	assert(Runtime.RequestAction(created.actor, "Combat.Fireball", { aim = 1 }))
	task.wait()
	expect(#created.commands.sent).toBe(1)
	expect(#recorded.checks).toBe(1)
	expect(#recorded.contexts).toBe(0)
end)

it("never predicts a Start that I5 refused locally", function()
	local created: Input.Fixture, recorded: Recorded = ready("Combat.Fireball")

	expect({ Runtime.RequestAction(created.actor, "Combat.Fireball", { aim = "wrong" }) }).toEqual({
		nil,
		"ActionPayloadInvalid",
	})

	task.wait()
	expect(#created.commands.sent).toBe(0)
	expect(#recorded.checks).toBe(0)
	expect(#recorded.contexts).toBe(0)
end)

it("adopts the real Accepted sequenceId and suppresses its replicated Start", function()
	local created: Input.Fixture, recorded: Recorded = ready("Combat.Fireball")

	assert(Runtime.RequestAction(created.actor, "Combat.Fireball", { aim = 1 }))
	task.wait()
	Observations.result(created, 1, "Start", "Accepted", 41)
	task.wait()
	expect(#recorded.contexts).toBe(1)

	expect(recorded.snapshots[#recorded.snapshots]).toEqual({
		startStatus = "Accepted",
		sequenceId = 41,
		inputTransitions = {},
	})
end)

it("suppresses a late preview when a same-stack Rejected reply precedes evaluation", function()
	local created: Input.Fixture, recorded: Recorded = ready("Combat.Fireball")

	assert(Runtime.RequestAction(created.actor, "Combat.Fireball", { aim = 1 }))
	Observations.result(created, 1, "Start", "Rejected", nil, "ActionNotGranted")
	task.wait()
	expect(#created.commands.sent).toBe(1)
	expect(#recorded.checks).toBe(0)
	expect(#recorded.contexts).toBe(0)
end)

it("retains the original input release and Stop admission that happened before create", function()
	local created: Input.Fixture, recorded: Recorded = ready("Combat.Rasengan")

	Input.set(created, { Input.route("Combat.Rasengan") })
	Input.tap(created)
	expect(#created.commands.sent).toBe(2)
	expect(#recorded.contexts).toBe(0)
	task.wait()

	expect(#recorded.contexts).toBe(1)
	local entry: Types.PresentationEntry = recorded.contexts[1].entry
	assert(entry.source == "ActionPrediction", "Expected a predicted Action entry")
	expect(entry.parameters).toEqual({ aim = 1 })

	local snapshot: Types.LocalPredictionSnapshot = recorded.snapshots[1]
	expect(snapshot.startStatus).toBe("Admitted")
	expect(#snapshot.inputTransitions).toBe(1)
	expect(snapshot.inputTransitions[1].transition).toBe("GenuineRelease")
	expect(snapshot.lastStop).toMatchObject({ status = "Admitted" })
end)

it("keeps the public I8 request event parameter-free while prediction consumes the private sidecar", function()
	local created: Input.Fixture, recorded: Recorded = ready("Combat.Fireball")
	local capture: Observations.Capture = Observations.capture()

	assert(Runtime.RequestAction(created.actor, "Combat.Fireball", { aim = 1 }))
	task.wait()
	expect(#recorded.contexts).toBe(1)
	Observations.parity(capture)
	capture.disconnect()
end)
