--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local afterEach: any = JestGlobals.afterEach
local ActorTypes = require(KRF.client.Actor.types)
local Types = require(KRF.client.Presentation.types)
local Events = require(KRF.client.Presentation.PresentationEvents)
local Actors: ActorTypes.ActorViewRegistryOwner = require(KRF.client.Actor.utils.ActorViewRegistryState)
local StateUtils = require(script.Parent.Utils.PresentationStateTestUtils)
local PredictionUtils = require(script.Parent.Utils.PresentationPredictionTestUtils)

afterEach(function()
	StateUtils.reset()
end)

local function cast(
	id: string,
	contexts: { Types.PresentationContext },
	predict: boolean?
): Types.PresentationDefinition
	return {
		id = id,
		entry = { event = Events.Action.Started, id = "Fireball" },
		predict = if predict == false then nil else true,
		create = function(context: Types.PresentationContext)
			table.insert(contexts, context)
		end,
	}
end

local function install(
	definitions: { Types.PresentationDefinition },
	policies: Types.ActionPredictionPolicies?,
	readiness: StateUtils.Readiness?
): PredictionUtils.Port
	local port: PredictionUtils.Port = PredictionUtils.port()

	StateUtils.install(definitions, readiness, PredictionUtils.policies(policies or { Fireball = {} }), port.port)

	return port
end

it(
	"creates the real instance once per opted-in definition for one admitted Start without waiting for a reply",
	function()
		local actor: StateUtils.Actor = StateUtils.actor("Caster")
		local first: { Types.PresentationContext } = {}
		local second: { Types.PresentationContext } = {}
		local authoritative: { Types.PresentationContext } = {}

		local port: PredictionUtils.Port =
			install({ cast("Cast", first), cast("Trail", second), cast("Plain", authoritative, false) })

		local start: PredictionUtils.Start = PredictionUtils.admit(port, actor.view, "Fireball", { aim = 3 })
		expect(#first).toBe(0)
		task.wait()
		expect(#first).toBe(1)
		expect(#second).toBe(1)
		expect(#authoritative).toBe(0)

		local entry: Types.PresentationEntry = first[1].entry
		assert(entry.source == "ActionPrediction", "Expected a predicted Action entry")

		expect(entry).toEqual({
			source = "ActionPrediction",
			event = "RequestAdmitted",
			actor = actor.view,
			actionId = "Fireball",
			originalStartKey = start.key,
			parameters = { aim = 3 },
		})

		local other: Types.PresentationEntry = second[1].entry
		assert(other.source == "ActionPrediction", "Expected a predicted Action entry")
		expect(table.isfrozen(entry)).toBe(true)
		expect(other.parameters).toEqual(entry.parameters)
		expect(other.parameters).never.toBe(entry.parameters)
		expect(first[1].actor).toBe(actor.view)
	end
)

it("evaluates one shared policy per admitted Start and isolates the decoded parameters it receives", function()
	local actor: StateUtils.Actor = StateUtils.actor("Caster")
	local contexts: { Types.PresentationContext } = {}
	local calls: number = 0

	local port: PredictionUtils.Port = install({ cast("Cast", contexts), cast("Trail", contexts) }, {
		Fireball = {
			canPredictStart = function(context: Types.ActionPredictionCheckContext): boolean?
				calls += 1
				context.parameters.aim = 100

				return true
			end,
		},
	})

	PredictionUtils.admit(port, actor.view, "Fireball", { aim = 3 })
	task.wait()
	expect(calls).toBe(1)
	expect(#contexts).toBe(2)

	for _, context: Types.PresentationContext in contexts do
		local entry: Types.PresentationEntry = context.entry
		assert(entry.source == "ActionPrediction", "Expected a predicted Action entry")
		expect(entry.parameters).toEqual({ aim = 3 })
	end
end)

it("skips the preview for blocked or undecided estimates but keeps normal authoritative creation", function()
	local actor: StateUtils.Actor = StateUtils.actor("Caster", { ["Status.Stunned"] = { stackCount = 1 } })

	local readiness: StateUtils.Readiness = StateUtils.readiness()
	readiness.ready[actor.view] = true

	local contexts: { Types.PresentationContext } = {}

	local port: PredictionUtils.Port = install(
		{ cast("Cast", contexts) },
		{ Fireball = { blockedTags = { "Status.Stunned" } } },
		readiness
	)

	local blocked: PredictionUtils.Start = PredictionUtils.admit(port, actor.view, "Fireball", { aim = 1 })
	task.wait()
	expect(#contexts).toBe(0)
	PredictionUtils.outcome(port, actor.view, "Fireball", blocked, "Accepted", 5)
	PredictionUtils.started(actor.actions, "Fireball", 5)
	task.wait()
	expect(#contexts).toBe(1)

	expect(contexts[1].entry).toEqual({
		source = "Action",
		event = "Started",
		actor = actor.view,
		action = { actionId = "Fireball", sequenceId = 5 },
	})

	readiness.ready[actor.view] = false
	StateUtils.commit(actor.tags, {})
	PredictionUtils.admit(port, actor.view, "Fireball", { aim = 1 })
	task.wait()
	expect(#contexts).toBe(1)
end)

it("never begins a prediction after a known Rejected outcome that arrived before evaluation", function()
	local actor: StateUtils.Actor = StateUtils.actor("Caster")
	local contexts: { Types.PresentationContext } = {}
	local calls: number = 0

	local port: PredictionUtils.Port = install({ cast("Cast", contexts) }, {
		Fireball = {
			canPredictStart = function(): boolean?
				calls += 1

				return true
			end,
		},
	})

	local start: PredictionUtils.Start = PredictionUtils.admit(port, actor.view, "Fireball", { aim = 1 })
	PredictionUtils.outcome(port, actor.view, "Fireball", start, "Rejected", nil, "ActionNotGranted")
	task.wait()
	expect(calls).toBe(0)
	expect(#contexts).toBe(0)
end)

it("cancels a scheduled create when Rejected arrives after evaluation but before construction", function()
	local actor: StateUtils.Actor = StateUtils.actor("Caster")
	local contexts: { Types.PresentationContext } = {}
	local port: PredictionUtils.Port

	port = install({ cast("Cast", contexts) }, {
		Fireball = {
			canPredictStart = function(context: Types.ActionPredictionCheckContext): boolean?
				task.defer(function()
					PredictionUtils.outcome(
						port,
						context.actor,
						"Fireball",
						{ key = context.originalStartKey, requestId = 1 },
						"Rejected"
					)
				end)

				return true
			end,
		},
	})

	PredictionUtils.admit(port, actor.view, "Fireball", { aim = 1 })
	task.wait()
	expect(#contexts).toBe(0)
end)

it("treats a missing or undecodable parameter sidecar as Unknown instead of guessing parameters", function()
	local actor: StateUtils.Actor = StateUtils.actor("Caster")
	local contexts: { Types.PresentationContext } = {}
	local calls: number = 0

	local port: PredictionUtils.Port = install({ cast("Cast", contexts) }, {
		Fireball = {
			canPredictStart = function(): boolean?
				calls += 1

				return true
			end,
		},
	})

	PredictionUtils.admit(port, actor.view, "Fireball", nil, { payload = false })
	PredictionUtils.admit(port, actor.view, "Fireball", nil, { encoded = "\255" })
	task.wait()
	expect(calls).toBe(0)
	expect(#contexts).toBe(0)
end)

it("ignores Starts for Actions without an opted-in definition even when a policy exists", function()
	local actor: StateUtils.Actor = StateUtils.actor("Caster")
	local contexts: { Types.PresentationContext } = {}
	local port: PredictionUtils.Port = install({ cast("Plain", contexts, false) }, { Fireball = {}, Dash = {} })

	PredictionUtils.admit(port, actor.view, "Fireball", { aim = 1 })
	PredictionUtils.admit(port, actor.view, "Dash", nil)
	task.wait()
	expect(#contexts).toBe(0)
	PredictionUtils.started(actor.actions, "Fireball", 3)
	task.wait()
	expect(#contexts).toBe(1)
end)

it("adopts the Accepted sequenceId without re-running create and scopes no-ID listeners to it", function()
	local actor: StateUtils.Actor = StateUtils.actor("Caster")
	local contexts: { Types.PresentationContext } = {}
	local ended: { number } = {}
	local creates: number = 0

	local port: PredictionUtils.Port = install({
		{
			id = "Cast",
			entry = { event = Events.Action.Started, id = "Fireball" },
			predict = true,
			create = function(context: Types.PresentationContext)
				creates += 1
				table.insert(contexts, context)

				context:On(Events.Action.Ended, function(event: Types.ActionEntryEvent)
					table.insert(ended, event.action.sequenceId)
				end)
			end,
		},
	})

	local start: PredictionUtils.Start = PredictionUtils.admit(port, actor.view, "Fireball", { aim = 1 })
	task.wait()
	actor.actions:FireEvent("Ended", table.freeze({ actionId = "Fireball", sequenceId = 9 }))
	task.wait()
	expect(ended).toEqual({})

	PredictionUtils.outcome(port, actor.view, "Fireball", start, "Accepted", 9)
	PredictionUtils.started(actor.actions, "Fireball", 9)
	actor.actions:FireEvent("Ended", table.freeze({ actionId = "Fireball", sequenceId = 8 }))
	actor.actions:FireEvent("Ended", table.freeze({ actionId = "Fireball", sequenceId = 9 }))
	task.wait()
	expect(creates).toBe(1)
	expect(ended).toEqual({ 9 })
	expect(contexts[1]:IsActive()).toBe(true)
	expect(contexts[1].entry.source).toBe("ActionPrediction")
end)

it("leaves a Rejected prediction active for the author to fade instead of finishing it", function()
	local actor: StateUtils.Actor = StateUtils.actor("Caster")
	local contexts: { Types.PresentationContext } = {}
	local port: PredictionUtils.Port = install({ cast("Cast", contexts) })

	local start: PredictionUtils.Start = PredictionUtils.admit(port, actor.view, "Fireball", { aim = 1 })
	task.wait()
	PredictionUtils.outcome(port, actor.view, "Fireball", start, "Rejected", nil, "ActionLocked")
	task.wait()
	expect(contexts[1]:IsActive()).toBe(true)
	contexts[1]:Finish()
	expect(contexts[1]:IsActive()).toBe(false)
end)

it("keeps bystander Actors and non-predicted definitions on ordinary authoritative creation", function()
	local caster: StateUtils.Actor = StateUtils.actor("Caster")
	local bystander: StateUtils.Actor = StateUtils.actor("Bystander")
	local predicted: { Types.PresentationContext } = {}
	local plain: { Types.PresentationContext } = {}
	local port: PredictionUtils.Port = install({ cast("Cast", predicted), cast("Plain", plain, false) })

	local start: PredictionUtils.Start = PredictionUtils.admit(port, caster.view, "Fireball", { aim = 1 })
	task.wait()
	PredictionUtils.started(bystander.actions, "Fireball", 1)
	PredictionUtils.outcome(port, caster.view, "Fireball", start, "Accepted", 2)
	PredictionUtils.started(caster.actions, "Fireball", 2)
	task.wait()

	expect(#predicted).toBe(2)
	expect(predicted[1].actor).toBe(caster.view)
	expect(predicted[2].actor).toBe(bystander.view)
	expect(predicted[2].entry.source).toBe("Action")
	expect(#plain).toBe(2)
	expect(plain[1].actor).toBe(bystander.view)
	expect(plain[2].actor).toBe(caster.view)
end)

it("retires predicted instances and their correlation with the original Actor", function()
	local actor: StateUtils.Actor = StateUtils.actor("Caster")
	local contexts: { Types.PresentationContext } = {}
	local port: PredictionUtils.Port = install({ cast("Cast", contexts) })

	local start: PredictionUtils.Start = PredictionUtils.admit(port, actor.view, "Fireball", { aim = 1 })
	task.wait()
	expect(contexts[1]:IsActive()).toBe(true)
	Actors.Remove(actor.view)
	expect(contexts[1]:IsActive()).toBe(false)
	PredictionUtils.outcome(port, actor.view, "Fireball", start, "Accepted", 4)
	task.wait()
	expect(#contexts).toBe(1)
end)

it("fences prediction work and authored code after the runtime shuts down", function()
	local actor: StateUtils.Actor = StateUtils.actor("Caster")
	local contexts: { Types.PresentationContext } = {}
	local calls: number = 0

	local port: PredictionUtils.Port = install({ cast("Cast", contexts) }, {
		Fireball = {
			canPredictStart = function(): boolean?
				calls += 1

				return true
			end,
		},
	})

	PredictionUtils.admit(port, actor.view, "Fireball", { aim = 1 })
	StateUtils.reset()
	task.wait()
	expect(calls).toBe(0)
	expect(#contexts).toBe(0)
	expect(next(port.observers)).toBeNil()
	expect(next(port.payloads)).toBeNil()
end)

it("bounds pending correlation and reports instead of predicting past the attempt limit", function()
	local actor: StateUtils.Actor = StateUtils.actor("Caster")
	local contexts: { Types.PresentationContext } = {}
	local port: PredictionUtils.Port = install({ cast("Cast", contexts) })

	for _ = 1, 33 do
		PredictionUtils.admit(port, actor.view, "Fireball", { aim = 1 })
	end

	task.wait()
	expect(#contexts).toBe(32)

	contexts[1]:Finish()
	task.wait()
	PredictionUtils.admit(port, actor.view, "Fireball", { aim = 1 })
	task.wait()
	expect(#contexts).toBe(33)
end)

it("installs no I8 observers when no definition opts in to prediction", function()
	local actor: StateUtils.Actor = StateUtils.actor("Caster")
	local contexts: { Types.PresentationContext } = {}
	local port: PredictionUtils.Port = install({ cast("Plain", contexts, false) })

	expect(next(port.observers)).toBeNil()
	expect(next(port.payloads)).toBeNil()
	PredictionUtils.started(actor.actions, "Fireball", 1)
	task.wait()
	expect(#contexts).toBe(1)
end)

it("diagnoses a failing callback and skips only the preview", function()
	local actor: StateUtils.Actor = StateUtils.actor("Caster")
	local contexts: { Types.PresentationContext } = {}

	local port: PredictionUtils.Port = install({ cast("Cast", contexts) }, {
		Fireball = {
			canPredictStart = function(): boolean?
				error("range check failed", 0)
			end,
		},
	})

	local start: PredictionUtils.Start = PredictionUtils.admit(port, actor.view, "Fireball", { aim = 1 })
	task.wait()
	expect(#contexts).toBe(0)
	PredictionUtils.outcome(port, actor.view, "Fireball", start, "Accepted", 2)
	PredictionUtils.started(actor.actions, "Fireball", 2)
	task.wait()
	expect(#contexts).toBe(1)
	expect(contexts[1].entry.source).toBe("Action")
end)

it("ignores admitted Starts for other Actions that have a policy but no opted-in definition", function()
	local actor: StateUtils.Actor = StateUtils.actor("Caster")
	local contexts: { Types.PresentationContext } = {}
	local port: PredictionUtils.Port = install({ cast("Cast", contexts) }, { Fireball = {}, Dash = {} })

	PredictionUtils.admit(port, actor.view, "Dash", nil)
	task.wait()
	expect(#contexts).toBe(0)
end)

it("degrades to authoritative creation when the active-instance limit refuses the preview", function()
	local actor: StateUtils.Actor = StateUtils.actor("Caster")
	local contexts: { Types.PresentationContext } = {}

	local port: PredictionUtils.Port = install({
		cast("Cast", contexts),
		{ id = "Flood", entry = { event = Events.Tag.Added, id = "Flood" }, create = function() end },
	})

	for _ = 1, 256 do
		actor.tags:FireEvent("Added", "Flood")
	end

	PredictionUtils.admit(port, actor.view, "Fireball", { aim = 1 })
	task.wait()
	expect(#contexts).toBe(0)
	StateUtils.reset()
end)
