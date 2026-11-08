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
local NetworkingTypes = require(KRF.client.Networking.types)
local ActorTypes = require(KRF.client.Actor.types)
local Runtime: Types.ClientActionRuntime = require(KRF.client.Action.ClientActionRuntime)
local Client = require(KRF.client)
local State = require(KRF.client.Action.utils.ClientActionRuntimeState)
local Requests = require(KRF.client.ActionRequest.utils.ClientActionRequestState)
local Commands = require(KRF.client.Networking.utils.CommandRuntimeState)
local Registry = require(KRF.client.Actor.utils.ActorViewRegistryState)
local Utils = require(script.Parent.Utils.ActionInputTestUtils)
local fixture: Utils.Fixture
local sending: boolean

beforeEach(function()
	fixture = Utils.new()
	sending = false
	local send = fixture.commands.client.transport.SendReliable

	fixture.commands.client.transport.SendReliable = function(payload: buffer): ()
		sending = true
		send(payload)
		sending = false
	end
end)

afterEach(function()
	Utils.destroy(fixture)
end)

local function ready(policies: Types.ActionInputPolicies?): Types.ActionInputOwner
	Utils.ready(fixture, policies or Utils.policies())
	Utils.set(fixture, { Utils.route("Combat.Rasengan") })

	return assert(State.GetInput())
end

it("reports admitted Start then early genuine release then Stop outside physical egress", function()
	local owner: Types.ActionInputOwner = ready()
	local order: { string } = {}
	local admissions: { RequestTypes.ActionRequestAdmission } = {}
	local release: Types.ActionInputDecision?

	assert(Requests.Get()):ObserveAdmissions(function(admission): ()
		expect(sending).toBe(false)
		table.insert(admissions, admission)
		table.insert(order, admission.kind)
	end)

	owner.ObserveDecisions(function(fact): ()
		expect(sending).toBe(false)
		release = fact
		table.insert(order, fact.kind)
	end)

	local entered: boolean = false

	fixture.commands.beforeSend = function(): ()
		if not entered then
			entered = true
			Utils.emit(fixture, "Released")
		end
	end

	Utils.emit(fixture, "Pressed")
	expect(order).toEqual({ "Start", "GenuineRelease", "Stop" })
	local fact: Types.ActionInputDecision = assert(release, "Expected original release fact")
	expect(table.isfrozen(fact)).toBe(true)
	expect(fact.original).toBe(admissions[1])
	expect(fact.original.inputTimestamp).toBe(100)
	expect(fact.original.requestKey).toBe(admissions[2].originalStartKey)
	expect(fact.generation > 0).toBe(true)
end)

it("stages release before reservation until original Start admission exists", function()
	local owner: Types.ActionInputOwner = ready()
	local order: { string } = {}

	assert(Requests.Get()):ObserveAdmissions(function(admission): ()
		table.insert(order, admission.kind)
	end)

	owner.ObserveDecisions(function(fact): ()
		table.insert(order, fact.kind)
	end)

	local commands: NetworkingTypes.ClientCommandRuntime = assert(Commands.Get())
	local send = commands._SendAdmitted

	commands._SendAdmitted = function(
		self: NetworkingTypes.ClientCommandRuntime,
		id: string,
		actor: ActorTypes.ActorView?,
		parameters: any?,
		admit: NetworkingTypes.CommandAdmission,
		committed: ((number) -> ())?
	): (number?, string?)
		if id == "KRF.Action.Start" then
			Utils.emit(fixture, "Released")
		end

		return send(self, id, actor, parameters, admit, committed)
	end

	Utils.emit(fixture, "Pressed")
	expect(order).toEqual({ "Start", "GenuineRelease", "Stop" })
	expect(#Utils.packets(fixture)).toBe(2)
end)

it("reports genuine local intent even when the Stop producer fails before admission", function()
	local policies: Types.ActionInputPolicies = Utils.policies()

	policies["Combat.Rasengan"].stopParameters = function(): any
		error("Aim unavailable")
	end

	local owner: Types.ActionInputOwner = ready(policies)
	local kinds: { string } = {}

	owner.ObserveDecisions(function(fact): ()
		table.insert(kinds, fact.kind)
	end)

	Utils.tap(fixture)
	expect(kinds).toEqual({ "GenuineRelease" })

	expect(Utils.packets(fixture)[2]).toMatchObject({
		kind = "KRF.Action.Interrupt",
		reason = "StopPreparationFailed",
		originalStartRequestId = 1,
	})
end)

it("keeps original manual correlation after Keep detachment without synthetic release facts", function()
	local owner: Types.ActionInputOwner = ready()
	Utils.set(fixture, { Utils.route("Mode.Aura") })
	local facts: { Types.ActionInputDecision } = {}

	owner.ObserveDecisions(function(fact): ()
		table.insert(facts, fact)
	end)

	Utils.tap(fixture)
	Runtime.RemoveProfileSource(fixture.actor, "Base")
	expect(#Utils.packets(fixture)).toBe(1)
	expect(#facts).toBe(1)
	expect(facts[1].kind).toBe("InvalidatedKeep")
	expect(facts[1].original.actor).toBe(fixture.actor)
	expect({ Runtime.RequestStop(1) }).toEqual({ 2 })
	expect(#facts).toBe(1)
	Utils.set(fixture, { Utils.route("Mode.Aura") })
	Utils.tap(fixture)
	expect(Utils.packets(fixture)[3].kind).toBe("KRF.Action.Start")
end)

it("retires automatic ownership before a direct Stop's transport can release the key", function()
	local owner: Types.ActionInputOwner = ready()
	local facts: { string } = {}

	owner.ObserveDecisions(function(fact): ()
		table.insert(facts, fact.kind)
	end)

	Utils.emit(fixture, "Pressed")

	fixture.commands.beforeSend = function(): ()
		fixture.commands.beforeSend = nil
		Utils.emit(fixture, "Released")
	end

	expect({ Runtime.RequestStop(1, { releaseAim = 8 }) }).toEqual({ 2 })
	expect(#Utils.packets(fixture)).toBe(2)
	expect(facts).toEqual({})
	expect(owner.Guard.HasActive()).toBe(false)
	Utils.outcome(fixture, 1, "KRF.Action.Start", "Accepted")
	expect(assert(Requests.Get()):GetOriginalStart(1)).toBeNil()
end)

it("rejects nested manual follow-up at the input mutation boundary", function()
	local policies: Types.ActionInputPolicies = Utils.policies()
	local nested: { any } = {}

	policies["Combat.Rasengan"].stopParameters = function(context: Types.ActionInputContext): any
		nested = {
			Runtime.RequestStop(
				assert(context.originalStartRequestId, "Expected original receipt"),
				{ releaseAim = 7 }
			),
		}

		Utils.emit(fixture, "Released")

		return { releaseAim = 2 }
	end

	ready(policies)
	Utils.tap(fixture)
	expect(nested).toEqual({ nil, "DispatchInProgress" })
	expect(#Utils.packets(fixture)).toBe(2)
end)

it("honors a newer Actor invalidation during release production without sending stale Stop", function()
	local policies: Types.ActionInputPolicies = Utils.policies()

	policies["Combat.Rasengan"].stopParameters = function(): any
		Registry.Invalidate(fixture.actor, "ActorUnavailable")

		return { releaseAim = 2 }
	end

	local owner: Types.ActionInputOwner = ready(policies)
	local kinds: { string } = {}

	owner.ObserveDecisions(function(fact): ()
		if fact.kind == "InvalidatedInterrupt" then
			expect(Registry.IsInvalidationInProgress()).toBe(false)
			expect(fixture.input.GetCommitContext()).toBeNil()
		end

		table.insert(kinds, fact.kind)
	end)

	Utils.tap(fixture)
	expect(kinds).toEqual({ "GenuineRelease", "InvalidatedInterrupt" })
	expect(#Utils.packets(fixture)).toBe(2)
	expect(Utils.packets(fixture)[2]).toMatchObject({ kind = "KRF.Action.Interrupt", reason = "ActorSwitched" })
end)

it("contains observer faults and yields and respects disconnection during decision delivery", function()
	local owner: Types.ActionInputOwner = ready()
	local laterCalls: number = 0
	local disconnectLater: (() -> ())?

	owner.ObserveDecisions(function(): ()
		assert(disconnectLater, "Expected later observer")()
		error("Preview fault")
	end)

	owner.ObserveDecisions(function(): ()
		coroutine.yield()
	end)

	disconnectLater = owner.ObserveDecisions(function(): ()
		laterCalls += 1
	end)

	Utils.tap(fixture)
	expect(laterCalls).toBe(0)
	expect(#Utils.packets(fixture)).toBe(2)
end)

it("makes old private owners and deferred input work inert after client teardown", function()
	local owner: Types.ActionInputOwner = ready()
	local selection: Types.ActionRouteSelection?
	local outcomes: { RequestTypes.ActionRequestOutcome } = {}

	assert(Requests.Get()):ObserveOutcomes(function(outcome): ()
		table.insert(outcomes, outcome)
	end)

	assert(State.Get()).ObserveSelection(function(value): ()
		selection = value
	end)

	Utils.emit(fixture, "Pressed")
	Client._ResetForTests()
	expect(#outcomes).toBe(1)

	expect(outcomes[1]).toMatchObject({
		status = "Unknown",
		reason = "CommandConnectionClosed",
		admission = { kind = "Start", requestId = 1 },
	})

	owner.Select(assert(selection, "Expected captured selection"), nil)
	expect({ owner.RequestAction(fixture.actor, "Mode.Aura") }).toEqual({ nil, "ClientNotReady" })
	expect({ owner.RequestStop(1) }).toEqual({ nil, "ClientNotReady" })
	expect({ owner.RequestInterrupt(1, "FocusLost") }).toEqual({ nil, "ClientNotReady" })
	local calls: number = 0

	expect({ fixture.input.AfterCommit(function(): ()
		calls += 1
	end) }).toEqual({ false, "ClientNotReady" })

	expect(calls).toBe(0)
	expect(#Utils.packets(fixture)).toBe(1)
end)

it("preserves a held activation when only shadowed profile metadata changes", function()
	local owner: Types.ActionInputOwner = ready()
	local kinds: { string } = {}

	owner.ObserveDecisions(function(fact): ()
		table.insert(kinds, fact.kind)
	end)

	Utils.emit(fixture, "Pressed")

	expect({
		Runtime.SetProfileSource(
			fixture.actor,
			"Fallback",
			{ priority = -1, routes = { Utils.route("Combat.Fireball") } }
		),
	}).toEqual({ true })

	expect(#Utils.packets(fixture)).toBe(1)
	Utils.emit(fixture, "Released")
	expect(kinds).toEqual({ "GenuineRelease" })
	expect(Utils.packets(fixture)[2]).toMatchObject({ kind = "KRF.Action.Stop", originalStartRequestId = 1 })
end)

it("discards a staged release observer after its lifecycle is destroyed during egress", function()
	local owner: Types.ActionInputOwner = ready()
	local calls: number = 0

	owner.ObserveDecisions(function(): ()
		calls += 1
	end)

	fixture.commands.beforeSend = function(): ()
		fixture.commands.beforeSend = nil
		Utils.emit(fixture, "Released")
		assert(State.Get(), "Expected live route owner").Destroy()
	end

	Utils.emit(fixture, "Pressed")
	expect(calls).toBe(0)
	expect(#Utils.packets(fixture)).toBe(1)
	expect(owner.Guard.HasActive()).toBe(false)
end)

it("drops automatic follow-ups when original authority retires before Start egress returns", function()
	local owner: Types.ActionInputOwner = ready()

	fixture.commands.beforeSend = function(): ()
		fixture.commands.beforeSend = nil
		assert(Requests.Get()):Retire(1)
		Utils.emit(fixture, "Released")
	end

	Utils.emit(fixture, "Pressed")
	expect(#Utils.packets(fixture)).toBe(1)
	expect(owner.Guard.HasActive()).toBe(false)
end)

it("publishes Actor-reset decisions after registry indexes and controlled selection are retired", function()
	local owner: Types.ActionInputOwner = ready()

	local observations: { { kind: string, barrier: boolean, viewCount: number, controlled: ActorTypes.ActorView? } } =
		{}

	owner.ObserveDecisions(function(fact): ()
		table.insert(observations, {
			kind = fact.kind,
			barrier = Registry.IsInvalidationInProgress(),
			viewCount = #Registry.GetAllActorViews(),
			controlled = Runtime.GetControlledActor(),
		})
	end)

	Utils.emit(fixture, "Pressed")
	Registry.Reset()
	expect(observations).toEqual({ { kind = "InvalidatedInterrupt", barrier = false, viewCount = 0 } })
	expect(Utils.packets(fixture)[2].kind).toBe("KRF.Action.Interrupt")
end)

it("resumes a newer invalidation after a manual Stop is refused during admission", function()
	ready()
	Utils.emit(fixture, "Pressed")
	local commands: NetworkingTypes.ClientCommandRuntime = assert(Commands.Get())
	local send = commands._SendAdmitted

	commands._SendAdmitted = function(
		self: NetworkingTypes.ClientCommandRuntime,
		id: string,
		actor: ActorTypes.ActorView?,
		parameters: any?,
		admit: NetworkingTypes.CommandAdmission,
		committed: ((number) -> ())?
	): (number?, string?)
		if id == "KRF.Action.Stop" then
			Registry.Invalidate(fixture.actor, "ActorUnavailable")

			return nil, "CommandPendingFull"
		end

		return send(self, id, actor, parameters, admit, committed)
	end

	expect({ Runtime.RequestStop(1, { releaseAim = 8 }) }).toEqual({ nil, "CommandPendingFull" })
	expect(#Utils.packets(fixture)).toBe(2)

	expect(Utils.packets(fixture)[2]).toMatchObject({
		kind = "KRF.Action.Interrupt",
		reason = "ActorSwitched",
		originalStartRequestId = 1,
	})
end)

it("reclaims automatic and request correlation across more completed cycles than the live bound", function()
	local owner: Types.ActionInputOwner = ready()
	local requests: RequestTypes.ClientActionRequestRuntime = assert(Requests.Get())

	for cycle = 1, 70 do
		Utils.tap(fixture)
		local original: number = cycle * 2 - 1
		Utils.outcome(fixture, original, "KRF.Action.Start", "Accepted")
		Utils.outcome(fixture, original + 1, "KRF.Action.Stop", "Accepted")
		expect(requests:_GetRetainedCountForTests()).toBe(0)
		expect(owner.Guard.HasActive()).toBe(false)
		fixture.clock.Advance(0.01)
	end

	expect(#Utils.packets(fixture)).toBe(140)
end)
