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
local RequestState = require(KRF.client.ActionRequest.utils.ClientActionRequestState)
local CommandState = require(KRF.client.Networking.utils.CommandRuntimeState)
local NetworkingTypes = require(KRF.client.Networking.types)
local ActorTypes = require(KRF.client.Actor.types)
local Utils = require(script.Parent.Utils.ActionInputTestUtils)
local fixture: Utils.Fixture
local policies: Types.ActionInputPolicies

beforeEach(function()
	fixture = Utils.new()
	policies = Utils.policies()
end)

afterEach(function()
	Utils.destroy(fixture)
end)

it("passes ephemeral resolver context to the Start producer and encodes its complete result without merging", function()
	local contextual: any = { techniqueId = "GameOwnedContext", aim = 99 }
	local produced: any = { aim = 4 }
	local startContext: Types.ActionInputContext? = nil
	local stopContext: Types.ActionInputContext? = nil

	policies["Combat.Rasengan"].startParameters = function(context): any
		startContext = context
		expect(context.resolvedParameters).toBe(contextual)

		return produced
	end

	policies["Combat.Rasengan"].stopParameters = function(context): any
		stopContext = context

		return { releaseAim = 5 }
	end

	Utils.ready(fixture, policies)

	Utils.set(fixture, {
		{
			when = Utils.key(),
			target = {
				kind = "Dynamic",
				resolve = function(): Types.ResolvedAction
					return { actionId = "Combat.Rasengan", parameters = contextual }
				end,
			},
		},
	})

	Utils.emit(fixture, "Pressed")
	Utils.started(fixture)
	produced.aim = 90
	contextual.aim = 91
	Utils.emit(fixture, "Released")
	expect(Utils.packets(fixture)[1].parameters).toEqual({ aim = 4 })
	local captured: Types.ActionInputContext = assert(startContext, "Selected Start must receive original metadata")
	expect(table.isfrozen(captured)).toBe(true)
	expect(captured.actor).toBe(fixture.actor)
	expect(captured.actionId).toBe("Combat.Rasengan")
	expect(captured.routeKey).toEqual(Utils.key())
	expect(captured.originalStartRequestId).toBeNil()
	expect(assert(stopContext).resolvedParameters).toBeNil()
end)

it("uses the entire I4 payload when the selected Action has no Start producer", function()
	policies["Combat.Fireball"].startParameters = nil
	Utils.ready(fixture, policies)
	local parameters: any = { aim = 6 }

	Utils.set(fixture, {
		{
			when = Utils.key(),
			target = {
				kind = "Dynamic",
				resolve = function(): Types.ResolvedAction
					return { actionId = "Combat.Fireball", parameters = parameters }
				end,
			},
		},
	})

	Utils.tap(fixture)
	parameters.aim = 80

	expect(Utils.packets(fixture)).toEqual({
		{ kind = "KRF.Action.Start", requestId = 1, actionId = "Combat.Fireball", parameters = { aim = 6 } },
	})
end)

local failures: { { name: string, produce: (string) -> any } } = {
	{
		name = "throw",
		produce = function(): any
			error("Expected parameter failure", 0)
		end,
	},
	{
		name = "yield",
		produce = function(): any
			coroutine.yield()

			return { aim = 88, releaseAim = 88 }
		end,
	},
	{
		name = "nil",
		produce = function(): any
			return nil
		end,
	},
	{
		name = "wrong type",
		produce = function(): any
			return "bad payload"
		end,
	},
	{
		name = "non-finite scalar",
		produce = function(phase: string): any
			return if phase == "Start" then { aim = math.huge } else { releaseAim = math.huge }
		end,
	},
	{
		name = "extra fields",
		produce = function(): any
			return { aim = 1, releaseAim = 1, extra = true }
		end,
	},
}

for _, case in failures do
	it(
		"aborts a selected Start on producer " .. case.name .. " without follow-up or local activation leakage",
		function()
			local calls: number = 0

			policies["Combat.Rasengan"].startParameters = function(): any
				calls += 1

				return if calls == 1 then case.produce("Start") else { aim = 2 }
			end

			Utils.ready(fixture, policies)
			Utils.set(fixture, { Utils.route("Combat.Rasengan") })
			Utils.tap(fixture)
			expect(calls).toBe(1)
			expect(Utils.packets(fixture)).toEqual({})
			local requests: RequestTypes.ClientActionRequestRuntime = assert(RequestState.Get())
			expect(requests:_GetRetainedCountForTests()).toBe(0)
			Utils.tap(fixture)
			expect(Utils.packets(fixture)[1]).toMatchObject({ kind = "KRF.Action.Start", parameters = { aim = 2 } })
			expect(#Utils.packets(fixture)).toBe(2)
		end
	)

	it("falls back once to original Interrupt on pre-admission Stop producer " .. case.name, function()
		local calls: number = 0

		policies["Combat.Rasengan"].stopParameters = function(): any
			calls += 1

			return case.produce("Stop")
		end

		Utils.ready(fixture, policies)
		Utils.set(fixture, { Utils.route("Combat.Rasengan") })
		Utils.emit(fixture, "Pressed")
		local original: number = Utils.started(fixture)
		Utils.emit(fixture, "Released")
		Utils.emit(fixture, "Released")
		expect(calls).toBe(1)

		expect(Utils.packets(fixture)[2]).toEqual({
			kind = "KRF.Action.Interrupt",
			requestId = 2,
			originalStartRequestId = original,
			actionId = "Combat.Rasengan",
			reason = "StopPreparationFailed",
		})

		expect(#Utils.packets(fixture)).toBe(2)
	end)
end

it(
	"rechecks the selected WhileDown epoch after a consumer producer and refuses a stale owner without Start-Stop synthesis",
	function()
		local lost: boolean = false
		local calls: number = 0

		policies["Combat.Rasengan"].startParameters = function(): any
			calls += 1
			lost = true

			return { aim = 1 }
		end

		Utils.ready(fixture, policies)
		local isActive = fixture.input.IsPressEpochActive

		fixture.input.IsPressEpochActive = function(inputId: string, epoch: number, generation: number): boolean
			return not lost and isActive(inputId, epoch, generation)
		end

		Utils.set(fixture, { Utils.route("Combat.Rasengan") })
		Utils.tap(fixture)
		expect(calls).toBe(1)
		expect(Utils.packets(fixture)).toEqual({})
	end
)

it("discards a non-admitted provisional Start and sends no phantom Stop on release", function()
	Utils.ready(fixture, policies)
	Utils.set(fixture, { Utils.route("Combat.Rasengan") })
	local commands: NetworkingTypes.ClientCommandRuntime = assert(CommandState.Get())
	local send = commands._SendAdmitted
	local refused: boolean = true
	local attempts: { string } = {}

	commands._SendAdmitted = function(
		self: NetworkingTypes.ClientCommandRuntime,
		commandId: string,
		actor: ActorTypes.ActorView?,
		parameters: any?,
		admit: NetworkingTypes.CommandAdmission,
		committed: ((number) -> ())?
	): (number?, string?)
		table.insert(attempts, commandId)

		if refused then
			return nil, "CommandPendingFull"
		end

		return send(self, commandId, actor, parameters, admit, committed)
	end

	Utils.tap(fixture)
	expect(attempts).toEqual({ "KRF.Action.Start" })
	expect(Utils.packets(fixture)).toEqual({})
	expect(assert(RequestState.Get()):_GetRetainedCountForTests()).toBe(0)
	refused = false
	Utils.tap(fixture)
	expect(#Utils.packets(fixture)).toBe(2)
end)

it("stages an early release during physical Start egress against the reserved original receipt", function()
	local entered: boolean = false
	local stopCalls: number = 0

	policies["Combat.Rasengan"].stopParameters = function(): any
		stopCalls += 1

		return { releaseAim = 7 }
	end

	Utils.ready(fixture, policies)
	Utils.set(fixture, { Utils.route("Combat.Rasengan") })

	fixture.commands.beforeSend = function(): ()
		if not entered then
			entered = true
			Utils.emit(fixture, "Released")
		end
	end

	Utils.emit(fixture, "Pressed")
	local original: number = Utils.started(fixture)
	expect(entered).toBe(true)
	expect(stopCalls).toBe(1)

	expect(Utils.packets(fixture)[2]).toMatchObject({
		kind = "KRF.Action.Stop",
		originalStartRequestId = original,
		parameters = { releaseAim = 7 },
	})

	expect(#Utils.packets(fixture)).toBe(2)
end)

it("contains a reentrant duplicate release inside the original Stop producer", function()
	local calls: number = 0

	policies["Combat.Rasengan"].stopParameters = function(): any
		calls += 1
		Utils.emit(fixture, "Released")

		return { releaseAim = 2 }
	end

	Utils.ready(fixture, policies)
	Utils.set(fixture, { Utils.route("Combat.Rasengan") })
	Utils.tap(fixture)
	expect(calls).toBe(1)
	expect(#Utils.packets(fixture)).toBe(2)
end)

it("does not retry or escalate an already admitted Stop after Unknown or a late result", function()
	Utils.ready(fixture, policies)
	local seen: { string } = {}

	assert(RequestState.Get()):ObserveOutcomes(function(outcome: RequestTypes.ActionRequestOutcome): ()
		table.insert(seen, outcome.admission.kind .. ":" .. outcome.status)
	end)

	Utils.set(fixture, { Utils.route("Combat.Rasengan") })
	Utils.tap(fixture)
	local original: number = Utils.started(fixture)
	expect(#Utils.packets(fixture)).toBe(2)
	fixture.clock.Advance(11)
	expect(seen).toContain("Stop:Unknown")
	Utils.outcome(fixture, original, "KRF.Action.Start", "Accepted")
	Utils.outcome(fixture, 2, "KRF.Action.Stop", "Rejected", "ActionNotRunning")
	fixture.clock.Advance(40)
	Utils.emit(fixture, "Released")
	expect(#Utils.packets(fixture)).toBe(2)
end)

it("falls back to original Interrupt when I5 refuses Stop encoding before N9 admission", function()
	Utils.ready(fixture, policies)
	Utils.set(fixture, { Utils.route("Combat.Rasengan") })
	Utils.emit(fixture, "Pressed")
	local original: number = Utils.started(fixture)
	local requests: RequestTypes.ClientActionRequestRuntime = assert(RequestState.Get())
	local attempts: number = 0

	requests.Stop = function(_self: RequestTypes.ClientActionRequestRuntime, requestId: number): (number?, string?)
		attempts += 1
		expect(requestId).toBe(original)

		return nil, "ActionPayloadInvalid"
	end

	Utils.emit(fixture, "Released")
	expect(attempts).toBe(1)

	expect(Utils.packets(fixture)[2]).toMatchObject({
		kind = "KRF.Action.Interrupt",
		originalStartRequestId = original,
		reason = "StopPreparationFailed",
	})

	expect(#Utils.packets(fixture)).toBe(2)
end)

it(
	"does not treat admission pressure as encoding failure and upgrades only after an actual newer invalidation",
	function()
		Utils.ready(fixture, policies)
		Utils.set(fixture, { Utils.route("Combat.Rasengan") })
		Utils.emit(fixture, "Pressed")
		local original: number = Utils.started(fixture)
		local requests: RequestTypes.ClientActionRequestRuntime = assert(RequestState.Get())
		local attempts: number = 0

		requests.Stop = function(): (number?, string?)
			attempts += 1

			return nil, "CommandPendingFull"
		end

		Utils.emit(fixture, "Released")
		Utils.emit(fixture, "Released")
		expect(attempts).toBe(1)
		expect(#Utils.packets(fixture)).toBe(1)
		expect({ Runtime.RemoveProfileSource(fixture.actor, "Base") }).toEqual({ true })

		expect(Utils.packets(fixture)[2]).toMatchObject({
			kind = "KRF.Action.Interrupt",
			originalStartRequestId = original,
		})

		expect(#Utils.packets(fixture)).toBe(2)
	end
)

it("retires a definitively rejected Start without invoking a release hook or sending a follow-up", function()
	local calls: number = 0

	policies["Combat.Rasengan"].stopParameters = function(): any
		calls += 1

		return { releaseAim = 2 }
	end

	Utils.ready(fixture, policies)
	Utils.set(fixture, { Utils.route("Combat.Rasengan") })
	Utils.emit(fixture, "Pressed")
	local original: number = Utils.started(fixture)
	Utils.outcome(fixture, original, "KRF.Action.Start", "Rejected", "ActionNotGranted")
	Utils.emit(fixture, "Released")
	expect(calls).toBe(0)
	expect(#Utils.packets(fixture)).toBe(1)
end)

it("keeps original release intent through Unknown Start and late acceptance without replay", function()
	Utils.ready(fixture, policies)
	Utils.set(fixture, { Utils.route("Combat.Rasengan") })
	Utils.emit(fixture, "Pressed")
	local original: number = Utils.started(fixture)
	fixture.clock.Advance(11)
	Utils.outcome(fixture, original, "KRF.Action.Start", "Accepted")
	Utils.emit(fixture, "Released")
	expect(Utils.packets(fixture)[2]).toMatchObject({ kind = "KRF.Action.Stop", originalStartRequestId = original })
	expect(#Utils.packets(fixture)).toBe(2)
end)
