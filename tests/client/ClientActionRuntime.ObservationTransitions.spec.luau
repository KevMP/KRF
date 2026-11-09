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
local Controls = require(KRF.client.Controls.ClientControls)
local State = require(KRF.client.Action.utils.ClientActionRuntimeState)
local Commands = require(KRF.client.Networking.utils.CommandRuntimeState)
local Input = require(script.Parent.Utils.ActionInputTestUtils)
local Utils = require(script.Parent.Utils.ActionObservationTestUtils)
local fixture: Input.Fixture
local capture: Utils.Capture?
local disconnect: (() -> ())?

beforeEach(function()
	fixture = Input.new()
	capture, disconnect = nil, nil
end)

afterEach(function()
	if capture ~= nil then
		capture.disconnect()
	end

	if disconnect ~= nil then
		disconnect()
	end

	Input.destroy(fixture)
end)

local function ready(policies: Types.ActionInputPolicies?): Utils.Capture
	Input.ready(fixture, policies or Input.policies())
	local created: Utils.Capture = Utils.capture()
	capture = created

	return created
end

it("observes final-Z Start and exactly one original genuine release before its Stop admission", function()
	local facts: Utils.Capture = ready()

	assert(
		fixture.input.SetSource(
			"Signs",
			{ sequences = { Cast = { steps = { "X", "Q", "Z" }, maxGapSeconds = 0.5, maxTotalSeconds = 2 } } }
		)
	)

	Input.set(fixture, {
		Input.route("Combat.Rasengan", { kind = "Sequence", sequenceId = "Cast" }),
		Input.route("Combat.Fireball", Input.key("Z")),
	})

	Input.tap(fixture, "X")
	fixture.clock.Advance(0.125)
	Input.tap(fixture, "Q")
	fixture.clock.Advance(0.125)
	Input.emit(fixture, "Pressed", "Z")
	Input.emit(fixture, "Released", "X")
	Input.emit(fixture, "Released", "Q")
	expect(#facts.private).toBe(1)
	Input.emit(fixture, "Released", "Z")
	Input.emit(fixture, "Released", "Z")
	expect(Utils.kinds(facts.private)).toEqual({ "RequestAdmitted:Start", "GenuineRelease", "RequestAdmitted:Stop" })
	expect(Utils.fact(facts.private, 1)).toMatchObject({ actionId = "Combat.Rasengan", inputOccurredAt = 100.25 })

	for index, fact: Types.ActionRequestEvent in facts.private do
		expect(fact).toMatchObject({
			originalStartRequestId = 1,
			originalStartKey = facts.private[1].originalStartKey,
			actor = fixture.actor,
			eventOrdinal = index,
		})
	end

	Utils.parity(facts)
end)

it("retains original Rasengan identity when equipment changes behind a continuous dynamic route", function()
	local facts: Utils.Capture = ready()
	local equipped: string = "Combat.Rasengan"
	local resolutions: number = 0

	local route: Types.ActionRoute = {
		when = Input.key(),
		target = {
			kind = "Dynamic",
			resolve = function(): Types.ResolvedAction
				resolutions += 1

				return { actionId = equipped }
			end,
		},
	}

	Input.set(fixture, { route })
	Input.emit(fixture, "Pressed")
	equipped = "Combat.Fireball"

	assert(Controls.Apply({
		profiles = { { kind = "Set", actor = fixture.actor, sourceId = "Base", profile = { routes = { route } } } },
	}))

	expect(resolutions).toBe(1)
	expect(#facts.private).toBe(1)
	Input.emit(fixture, "Released")

	expect(Utils.fact(facts.private, 2)).toMatchObject({
		kind = "InputTransition",
		transition = "GenuineRelease",
		actionId = "Combat.Rasengan",
	})

	expect(Input.packets(fixture)[2].parameters).toEqual({ releaseAim = 2 })
	Input.tap(fixture)

	expect(Utils.fact(facts.private, 4)).toMatchObject({
		kind = "RequestAdmitted",
		actionId = "Combat.Fireball",
		originalStartRequestId = 3,
	})

	expect(#facts.private).toBe(4)
	Utils.parity(facts)
end)

it("distinguishes ToggleOff from physical release and keeps Stop nonterminal", function()
	local facts: Utils.Capture = ready()
	Input.set(fixture, { Input.route("Mode.Aura") })
	Input.tap(fixture)
	expect(Utils.kinds(facts.private)).toEqual({ "RequestAdmitted:Start" })
	Input.tap(fixture)
	expect(Utils.kinds(facts.private)).toEqual({ "RequestAdmitted:Start", "ToggleOff", "RequestAdmitted:Stop" })
	Utils.result(fixture, 2, "Stop", "Accepted")
	task.wait()

	expect(Utils.fact(facts.private, 4)).toMatchObject({
		kind = "RequestOutcome",
		operation = "Stop",
		status = "Accepted",
	})

	expect(#facts.private).toBe(4)
	Utils.parity(facts)
end)

for _, failure: string in { "Throw", "Yield", "InvalidPayload", "AdmissionRefused" } do
	it("keeps genuine release observable when Stop fails with " .. failure .. " before admission", function()
		local policies: Types.ActionInputPolicies = Input.policies()

		policies["Combat.Rasengan"].stopParameters = function(): any
			if failure == "Throw" then
				error("NoReleaseAim", 0)
			end

			if failure == "Yield" then
				coroutine.yield()
			end

			return { releaseAim = if failure == "InvalidPayload" then "wrong" else 2 }
		end

		local facts: Utils.Capture = ready(policies)
		Input.set(fixture, { Input.route("Combat.Rasengan") })
		Input.emit(fixture, "Pressed")

		if failure == "AdmissionRefused" then
			local commands = assert(Commands.Get())
			local send = commands._SendAdmitted

			commands._SendAdmitted = function(self, id, actor, parameters, admit, committed): (number?, string?)
				if id == "KRF.Action.Stop" then
					return nil, "CommandAdmissionRefused"
				end

				return send(self, id, actor, parameters, admit, committed)
			end
		end

		Input.emit(fixture, "Released")

		if failure == "AdmissionRefused" then
			expect(Utils.kinds(facts.private)).toEqual({ "RequestAdmitted:Start", "GenuineRelease" })
			expect(#Input.packets(fixture)).toBe(1)
		else
			expect(Utils.kinds(facts.private)).toEqual({
				"RequestAdmitted:Start",
				"GenuineRelease",
				"RequestAdmitted:Interrupt",
			})

			expect(Input.packets(fixture)[2].kind).toBe("KRF.Action.Interrupt")
		end

		Utils.parity(facts)
	end)
end

for _, keep: boolean in { false, true } do
	it("observes committed Actor switch with Keep=" .. tostring(keep) .. " before any original follow-up", function()
		local policies: Types.ActionInputPolicies = Input.policies()
		policies["Combat.Rasengan"].onInvalidation = if keep then "Keep" else "Interrupt"

		local facts: Utils.Capture = ready(policies)
		Input.set(fixture, { Input.route("Combat.Rasengan") })
		Input.emit(fixture, "Pressed")
		local snapshot: { actorCommitted: boolean, contextCommitted: boolean, fenceReleased: boolean, sent: number }?

		disconnect = State.ObserveActionRequest(function(fact: Types.ActionRequestEvent): ()
			if fact.kind == "InputTransition" then
				local context = fixture.input.GetContext("Gate")

				snapshot = {
					actorCommitted = Runtime.GetControlledActor() == fixture.other,
					contextCommitted = context ~= nil and not context.enabled,
					fenceReleased = fixture.input.GetCommitContext() == nil,
					sent = #fixture.commands.sent,
				}
			end
		end)

		assert(Controls.Apply({
			selection = { kind = "Set", actor = fixture.other },
			contexts = { { contextId = "Gate", enabled = false } },
		}))

		expect(snapshot).toEqual({ actorCommitted = true, contextCommitted = true, fenceReleased = true, sent = 1 })
		local transition: Types.ActionRequestEvent = Utils.fact(facts.private, 2)

		expect(transition).toMatchObject({
			kind = "InputTransition",
			transition = if keep then "InvalidatedKeep" else "InvalidatedInterrupt",
			actor = fixture.actor,
			actionId = "Combat.Rasengan",
			originalStartRequestId = 1,
		})

		expect(#fixture.commands.sent).toBe(if keep then 1 else 2)
		Input.emit(fixture, "Released")
		expect(#facts.private).toBe(if keep then 2 else 3)
		Utils.parity(facts)
	end)
end

it("never converts a native context-disable end into genuine release and emits nothing for rejected Apply", function()
	local facts: Utils.Capture = ready()
	Input.set(fixture, { Input.route("Combat.Rasengan") })
	Input.emit(fixture, "Pressed")
	local success: boolean = Controls.Apply({ contexts = { { contextId = "Missing", enabled = false } } })
	expect(success).toBe(false)
	expect(#facts.private).toBe(1)
	fixture.syntheticEnd = true
	assert(Controls.Apply({ contexts = { { contextId = "Combat", enabled = false } } }))

	expect(Utils.kinds(facts.private)).toEqual({
		"RequestAdmitted:Start",
		"InvalidatedInterrupt",
		"RequestAdmitted:Interrupt",
	})

	Utils.parity(facts)
end)

it("invalidates only the original route while preserving a valid native press epoch", function()
	local facts: Utils.Capture = ready()
	Input.set(fixture, { Input.route("Combat.Rasengan") })
	Input.emit(fixture, "Pressed")
	assert(Runtime.RemoveProfileSource(fixture.actor, "Base"))
	expect(fixture.states[fixture.actions.AbilitySlot1]).toBe(true)

	expect(Utils.kinds(facts.private)).toEqual({
		"RequestAdmitted:Start",
		"InvalidatedInterrupt",
		"RequestAdmitted:Interrupt",
	})

	Input.emit(fixture, "Released")
	expect(#facts.private).toBe(3)
	Utils.parity(facts)
end)
