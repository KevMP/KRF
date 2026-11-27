--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local afterEach: any = JestGlobals.afterEach
local ActorTypes = require(KRF.client.Actor.types)
local SignalTypes = require(KRF.shared.Signal.types)
local Types = require(KRF.client.Presentation.types)
local Events = require(KRF.client.Presentation.PresentationEvents)
local States = require(KRF.client.Presentation.PresentationStates)
local StateUtils = require(script.Parent.Utils.PresentationStateTestUtils)
local PredictionUtils = require(script.Parent.Utils.PresentationPredictionTestUtils)

afterEach(function()
	StateUtils.reset()
end)

type Watched = { contexts: { Types.PresentationContext }, snapshots: { Types.LocalPredictionSnapshot } }

local function install(actionId: string?, readiness: StateUtils.Readiness?): (PredictionUtils.Port, Watched)
	local watched: Watched = { contexts = {}, snapshots = {} }
	local port: PredictionUtils.Port = PredictionUtils.port()

	StateUtils.install({
		{
			id = "Cast",
			entry = { event = Events.Action.Started, id = actionId or "Charge" },
			predict = true,
			create = function(context: Types.PresentationContext)
				table.insert(watched.contexts, context)

				context:Watch(States.Action.LocalPrediction, function(snapshot: Types.LocalPredictionSnapshot)
					table.insert(watched.snapshots, snapshot)
				end)
			end,
		},
	}, readiness, PredictionUtils.policies({ Charge = {}, Fireball = {} }), port.port)

	return port, watched
end

it("delivers an initial snapshot holding every fact that arrived before create", function()
	local actor: StateUtils.Actor = StateUtils.actor("Caster")
	local port: PredictionUtils.Port, watched: Watched = install()

	local start: PredictionUtils.Start = PredictionUtils.admit(
		port,
		actor.view,
		"Charge",
		{ aim = 1 },
		{ origin = "Input" }
	)

	PredictionUtils.transition(port, actor.view, "Charge", start, "GenuineRelease", "InputReleased")
	PredictionUtils.followUp(port, actor.view, "Charge", start, "Stop", "Admitted", 2)
	PredictionUtils.outcome(port, actor.view, "Charge", start, "Unknown", nil, "CommandTimedOut")
	task.wait()

	expect(#watched.contexts).toBe(1)

	expect(watched.snapshots).toEqual({
		{
			startStatus = "Unknown",
			startReason = "CommandTimedOut",
			inputTransitions = { { transition = "GenuineRelease", reason = "InputReleased", eventOrdinal = 2 } },
			lastStop = { requestKey = "1:2", status = "Admitted" },
		},
	})

	expect(table.isfrozen(watched.snapshots[1])).toBe(true)
	expect(table.isfrozen(watched.snapshots[1].inputTransitions)).toBe(true)
end)

it("reports late Accepted after Unknown and keeps accepted Stop and Interrupt as non-terminal follow-ups", function()
	local actor: StateUtils.Actor = StateUtils.actor("Caster")
	local port: PredictionUtils.Port, watched: Watched = install()

	local start: PredictionUtils.Start = PredictionUtils.admit(port, actor.view, "Charge", { aim = 1 })
	task.wait()
	PredictionUtils.outcome(port, actor.view, "Charge", start, "Unknown")
	task.wait()
	PredictionUtils.outcome(port, actor.view, "Charge", start, "Accepted", 12)
	task.wait()
	PredictionUtils.followUp(port, actor.view, "Charge", start, "Stop", "Admitted", 2)
	PredictionUtils.followUp(port, actor.view, "Charge", start, "Interrupt", "Admitted", 3)
	PredictionUtils.followUp(port, actor.view, "Charge", start, "Stop", "Accepted", 2)
	PredictionUtils.followUp(port, actor.view, "Charge", start, "Interrupt", "Rejected", 3, "ActionInterruptDenied")
	task.wait()

	expect(#watched.snapshots).toBe(4)
	expect(watched.snapshots[2]).toMatchObject({ startStatus = "Unknown" })
	expect(watched.snapshots[3]).toMatchObject({ startStatus = "Accepted", sequenceId = 12 })

	expect(watched.snapshots[4]).toEqual({
		startStatus = "Accepted",
		sequenceId = 12,
		inputTransitions = {},
		lastStop = { requestKey = "1:2", status = "Accepted" },
		lastInterrupt = { requestKey = "1:3", status = "Rejected", reason = "ActionInterruptDenied" },
	})

	expect(watched.contexts[1]:IsActive()).toBe(true)
end)

it("keeps every bounded original input decision in order instead of only the latest", function()
	local actor: StateUtils.Actor = StateUtils.actor("Caster")
	local port: PredictionUtils.Port, watched: Watched = install()
	local start: PredictionUtils.Start = PredictionUtils.admit(port, actor.view, "Charge", { aim = 1 })

	for _, transition: any in { "InvalidatedKeep", "GenuineRelease", "ToggleOff", "InvalidatedInterrupt" } do
		PredictionUtils.transition(port, actor.view, "Charge", start, transition)
	end

	for _ = 1, 6 do
		PredictionUtils.transition(port, actor.view, "Charge", start, "ToggleOff")
	end

	task.wait()
	local decisions: { Types.LocalPredictionInputDecision } = watched.snapshots[1].inputTransitions
	expect(#decisions).toBe(8)
	expect(decisions[1]).toEqual({ transition = "InvalidatedKeep", eventOrdinal = 2 })
	expect(decisions[2].transition).toBe("GenuineRelease")
	expect(decisions[4].transition).toBe("InvalidatedInterrupt")
	expect(decisions[8].eventOrdinal).toBe(9)
end)

it("coalesces facts delivered in one frame into a single later snapshot", function()
	local actor: StateUtils.Actor = StateUtils.actor("Caster")
	local port: PredictionUtils.Port, watched: Watched = install()

	local start: PredictionUtils.Start = PredictionUtils.admit(port, actor.view, "Charge", { aim = 1 })
	task.wait()
	PredictionUtils.outcome(port, actor.view, "Charge", start, "Accepted", 3)
	PredictionUtils.followUp(port, actor.view, "Charge", start, "Stop", "Admitted", 2)
	task.wait()
	expect(#watched.snapshots).toBe(2)
	expect(watched.snapshots[2]).toMatchObject({ startStatus = "Accepted", lastStop = { status = "Admitted" } })
end)

it("ignores stale or repeated follow-up outcomes that do not belong to the latest request", function()
	local actor: StateUtils.Actor = StateUtils.actor("Caster")
	local port: PredictionUtils.Port, watched: Watched = install()

	local start: PredictionUtils.Start = PredictionUtils.admit(port, actor.view, "Charge", { aim = 1 })
	PredictionUtils.outcome(port, actor.view, "Charge", start, "Rejected", nil, "ActionNotGranted")
	PredictionUtils.outcome(port, actor.view, "Charge", start, "Accepted", 3)
	task.wait()
	expect(#watched.snapshots).toBe(0)

	local other: PredictionUtils.Start = PredictionUtils.admit(port, actor.view, "Charge", { aim = 1 })
	task.wait()
	PredictionUtils.followUp(port, actor.view, "Charge", other, "Stop", "Accepted", 9)
	PredictionUtils.followUp(port, actor.view, "Charge", other, "Stop", "Admitted", 10)
	PredictionUtils.followUp(port, actor.view, "Charge", other, "Stop", "Rejected", 9)
	task.wait()
	expect(watched.snapshots[#watched.snapshots].lastStop).toEqual({ requestKey = "1:10", status = "Admitted" })
end)

it("stops delivering after the Watch disconnects or the instance finishes", function()
	local actor: StateUtils.Actor = StateUtils.actor("Caster")
	local port: PredictionUtils.Port = PredictionUtils.port()
	local snapshots: { Types.LocalPredictionSnapshot } = {}
	local connection: SignalTypes.Connection? = nil
	local context: Types.PresentationContext? = nil

	StateUtils.install({
		{
			id = "Cast",
			entry = { event = Events.Action.Started, id = "Charge" },
			predict = true,
			create = function(created: Types.PresentationContext)
				context = created

				connection = created:Watch(
					States.Action.LocalPrediction,
					function(snapshot: Types.LocalPredictionSnapshot)
						table.insert(snapshots, snapshot)
					end
				)
			end,
		},
	}, nil, PredictionUtils.policies({ Charge = {} }), port.port)

	local start: PredictionUtils.Start = PredictionUtils.admit(port, actor.view, "Charge", { aim = 1 })
	task.wait()
	assert(connection, "Expected a Watch connection"):Disconnect()
	PredictionUtils.outcome(port, actor.view, "Charge", start, "Accepted", 3)
	task.wait()
	expect(#snapshots).toBe(1)
	assert(context, "Expected a predicted context"):Finish()
	PredictionUtils.transition(port, actor.view, "Charge", start, "GenuineRelease")
	task.wait()
	expect(#snapshots).toBe(1)
end)

it("retires the instance when a LocalPrediction Watch callback fails", function()
	local actor: StateUtils.Actor = StateUtils.actor("Caster")
	local port: PredictionUtils.Port = PredictionUtils.port()
	local contexts: { Types.PresentationContext } = {}

	StateUtils.install({
		{
			id = "Cast",
			entry = { event = Events.Action.Started, id = "Charge" },
			predict = true,
			create = function(context: Types.PresentationContext)
				table.insert(contexts, context)

				context:Watch(States.Action.LocalPrediction, function(): ()
					error("fade failed", 0)
				end)
			end,
		},
	}, nil, PredictionUtils.policies({ Charge = {} }), port.port)

	PredictionUtils.admit(port, actor.view, "Charge", { aim = 1 })
	task.wait()
	task.wait()
	expect(contexts[1]:IsActive()).toBe(false)
end)

it("rejects LocalPrediction Watch on an instance that did not originate from a local prediction", function()
	local actor: StateUtils.Actor = StateUtils.actor("Caster")
	local failures: { string } = {}

	StateUtils.install({
		{
			id = "Plain",
			entry = { event = Events.Action.Started, id = "Charge" },
			create = function(context: Types.PresentationContext)
				local success: boolean, failure: any = pcall(function()
					context:Watch(States.Action.LocalPrediction, function(_snapshot: Types.LocalPredictionSnapshot) end)
				end)

				expect(success).toBe(false)
				table.insert(failures, tostring(failure))
			end,
		},
	})

	PredictionUtils.started(actor.actions, "Charge", 1)
	task.wait()
	expect(#failures).toBe(1)
	expect(string.find(failures[1], "Watch: OriginPredictionMissing", 1, true) ~= nil).toBe(true)
end)

it("watches the predicted activation's current state as absent until Accepted and present ActionsView state", function()
	local actor: StateUtils.Actor = StateUtils.actor("Caster")

	local readiness: StateUtils.Readiness = StateUtils.readiness()
	readiness.ready[actor.view] = true

	local port: PredictionUtils.Port = PredictionUtils.port()
	local states: { number } = {}

	StateUtils.install({
		{
			id = "Cast",
			entry = { event = Events.Action.Started, id = "Charge" },
			predict = true,
			create = function(context: Types.PresentationContext)
				context:Watch(States.Action.Active, function(snapshot: ActorTypes.ActionSnapshot?)
					table.insert(
						states,
						if snapshot ~= nil and snapshot.actionId == "Charge" then snapshot.sequenceId else 0
					)
				end)
			end,
		},
	}, readiness, PredictionUtils.policies({ Charge = {} }), port.port)

	local start: PredictionUtils.Start = PredictionUtils.admit(port, actor.view, "Charge", { aim = 1 })
	task.wait()
	StateUtils.commit(actor.actions, { [5] = "Charge" })
	task.wait()
	expect(states).toEqual({ 0 })
	PredictionUtils.outcome(port, actor.view, "Charge", start, "Accepted", 5)
	task.wait()
	expect(states).toEqual({ 0, 5 })
	StateUtils.commit(actor.actions, {})
	task.wait()
	expect(states).toEqual({ 0, 5, 0 })
end)

it("shares one immutable snapshot between definitions and skips repeated identical outcomes", function()
	local actor: StateUtils.Actor = StateUtils.actor("Caster")
	local port: PredictionUtils.Port = PredictionUtils.port()
	local snapshots: { Types.LocalPredictionSnapshot } = {}

	local function watcher(id: string): Types.PresentationDefinition
		return {
			id = id,
			entry = { event = Events.Action.Started, id = "Charge" },
			predict = true,
			create = function(context: Types.PresentationContext)
				context:Watch(States.Action.LocalPrediction, function(snapshot: Types.LocalPredictionSnapshot)
					table.insert(snapshots, snapshot)
				end)
			end,
		}
	end

	StateUtils.install({ watcher("Cast"), watcher("Trail") }, nil, PredictionUtils.policies({ Charge = {} }), port.port)

	local start: PredictionUtils.Start = PredictionUtils.admit(port, actor.view, "Charge", { aim = 1 })
	task.wait()
	expect(#snapshots).toBe(2)
	expect(snapshots[1]).toBe(snapshots[2])
	PredictionUtils.outcome(port, actor.view, "Charge", start, "Unknown")
	task.wait()
	PredictionUtils.outcome(port, actor.view, "Charge", start, "Unknown")
	task.wait()
	expect(#snapshots).toBe(4)
end)

it("re-delivers an absent activation after adoption when Started and Ended both preceded the reply", function()
	local actor: StateUtils.Actor = StateUtils.actor("Caster")

	local readiness: StateUtils.Readiness = StateUtils.readiness()
	readiness.ready[actor.view] = true

	local port: PredictionUtils.Port = PredictionUtils.port()
	local states: { number } = {}
	local contexts: { Types.PresentationContext } = {}

	StateUtils.install({
		{
			id = "Cast",
			entry = { event = Events.Action.Started, id = "Charge" },
			predict = true,
			create = function(context: Types.PresentationContext)
				table.insert(contexts, context)

				context:Watch(States.Action.Active, function(snapshot: ActorTypes.ActionSnapshot?)
					table.insert(states, if snapshot ~= nil then snapshot.sequenceId else 0)
				end)
			end,
		},
	}, readiness, PredictionUtils.policies({ Charge = {} }), port.port)

	local start: PredictionUtils.Start = PredictionUtils.admit(port, actor.view, "Charge", { aim = 1 })
	task.wait()
	PredictionUtils.started(actor.actions, "Charge", 6)
	actor.actions:FireEvent("Ended", table.freeze({ actionId = "Charge", sequenceId = 6 }))
	task.wait()
	expect(states).toEqual({ 0 })
	PredictionUtils.outcome(port, actor.view, "Charge", start, "Accepted", 6)
	task.wait()
	expect(states).toEqual({ 0, 0 })
	expect(#contexts).toBe(1)
end)

it("ignores a repeated identical follow-up outcome", function()
	local actor: StateUtils.Actor = StateUtils.actor("Caster")
	local port: PredictionUtils.Port, watched: Watched = install()

	local start: PredictionUtils.Start = PredictionUtils.admit(port, actor.view, "Charge", { aim = 1 })
	PredictionUtils.followUp(port, actor.view, "Charge", start, "Stop", "Admitted", 2)
	task.wait()
	PredictionUtils.followUp(port, actor.view, "Charge", start, "Stop", "Unknown", 2)
	task.wait()
	PredictionUtils.followUp(port, actor.view, "Charge", start, "Stop", "Unknown", 2)
	task.wait()
	expect(#watched.snapshots).toBe(2)
	expect(watched.snapshots[2].lastStop).toEqual({ requestKey = "1:2", status = "Unknown" })
end)
