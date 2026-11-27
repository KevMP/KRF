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

local WINDOW_SECONDS: number = 0.5
local RETENTION_SECONDS: number = 20

afterEach(function()
	StateUtils.reset()
end)

local function cast(id: string, contexts: { Types.PresentationContext }, finish: boolean?): Types.PresentationDefinition
	return {
		id = id,
		entry = { event = Events.Action.Started, id = "Fireball" },
		predict = true,
		create = function(context: Types.PresentationContext)
			table.insert(contexts, context)

			if finish then
				context:Finish()
			end
		end,
	}
end

local function install(
	definitions: { Types.PresentationDefinition },
	policies: Types.ActionPredictionPolicies?
): PredictionUtils.Port
	local port: PredictionUtils.Port = PredictionUtils.port()
	StateUtils.install(definitions, nil, PredictionUtils.policies(policies or { Fireball = {} }), port.port)

	return port
end

local function sources(contexts: { Types.PresentationContext }): { string }
	local values: { string } = {}

	for _, context: Types.PresentationContext in contexts do
		table.insert(values, context.entry.source)
	end

	return values
end

it("suppresses the authoritative replay of an exactly known receipt-first activation", function()
	local actor: StateUtils.Actor = StateUtils.actor("Caster")
	local contexts: { Types.PresentationContext } = {}
	local port: PredictionUtils.Port = install({ cast("Cast", contexts) })

	local start: PredictionUtils.Start = PredictionUtils.admit(port, actor.view, "Fireball", { aim = 1 })
	task.wait()
	PredictionUtils.outcome(port, actor.view, "Fireball", start, "Accepted", 4)
	PredictionUtils.started(actor.actions, "Fireball", 4)
	task.wait()
	expect(sources(contexts)).toEqual({ "ActionPrediction" })
end)

it("keeps a correlation-only tombstone so an effect finished before its Start is not replayed", function()
	local actor: StateUtils.Actor = StateUtils.actor("Caster")
	local contexts: { Types.PresentationContext } = {}
	local port: PredictionUtils.Port = install({ cast("Burst", contexts, true) })

	local start: PredictionUtils.Start = PredictionUtils.admit(port, actor.view, "Fireball", { aim = 1 })
	task.wait()
	expect(contexts[1]:IsActive()).toBe(false)
	PredictionUtils.outcome(port, actor.view, "Fireball", start, "Accepted", 4)
	PredictionUtils.started(actor.actions, "Fireball", 4)
	task.wait()
	expect(#contexts).toBe(1)
	PredictionUtils.started(actor.actions, "Fireball", 4)
	task.wait()
	expect(sources(contexts)).toEqual({ "ActionPrediction", "Action" })
end)

it(
	"defers an authoritative-first Start while a candidate is unresolved and adopts it on the matching receipt",
	function()
		local actor: StateUtils.Actor = StateUtils.actor("Caster")
		local contexts: { Types.PresentationContext } = {}
		local port: PredictionUtils.Port = install({ cast("Cast", contexts) })

		local start: PredictionUtils.Start = PredictionUtils.admit(port, actor.view, "Fireball", { aim = 1 })
		task.wait()
		PredictionUtils.started(actor.actions, "Fireball", 4)
		task.wait()
		expect(#contexts).toBe(1)
		PredictionUtils.outcome(port, actor.view, "Fireball", start, "Accepted", 4)
		PredictionUtils.advance(port, WINDOW_SECONDS)
		task.wait()
		expect(sources(contexts)).toEqual({ "ActionPrediction" })
	end
)

it("adopts a held Start that arrived before evaluation into the single predicted instance", function()
	local actor: StateUtils.Actor = StateUtils.actor("Caster")
	local contexts: { Types.PresentationContext } = {}
	local port: PredictionUtils.Port = install({ cast("Cast", contexts) })

	local start: PredictionUtils.Start = PredictionUtils.admit(port, actor.view, "Fireball", { aim = 1 })
	PredictionUtils.started(actor.actions, "Fireball", 4)
	PredictionUtils.outcome(port, actor.view, "Fireball", start, "Accepted", 4)
	task.wait()
	expect(sources(contexts)).toEqual({ "ActionPrediction" })
end)

it("releases an unrelated deferred Start as soon as the candidate proves to be another activation", function()
	local actor: StateUtils.Actor = StateUtils.actor("Caster")
	local contexts: { Types.PresentationContext } = {}
	local port: PredictionUtils.Port = install({ cast("Cast", contexts) })

	local start: PredictionUtils.Start = PredictionUtils.admit(port, actor.view, "Fireball", { aim = 1 })
	task.wait()
	PredictionUtils.started(actor.actions, "Fireball", 6)
	task.wait()
	expect(#contexts).toBe(1)
	PredictionUtils.outcome(port, actor.view, "Fireball", start, "Accepted", 7)
	task.wait()
	expect(sources(contexts)).toEqual({ "ActionPrediction", "Action" })
	expect(contexts[2].entry).toMatchObject({ action = { sequenceId = 6 } })
	PredictionUtils.started(actor.actions, "Fireball", 7)
	task.wait()
	expect(#contexts).toBe(2)
end)

it("releases a deferred Start immediately when its only candidate is Rejected", function()
	local actor: StateUtils.Actor = StateUtils.actor("Caster")
	local contexts: { Types.PresentationContext } = {}
	local port: PredictionUtils.Port = install({ cast("Cast", contexts) })

	local start: PredictionUtils.Start = PredictionUtils.admit(port, actor.view, "Fireball", { aim = 1 })
	task.wait()
	PredictionUtils.started(actor.actions, "Fireball", 3)
	PredictionUtils.outcome(port, actor.view, "Fireball", start, "Rejected", nil, "ActionLocked")
	task.wait()
	expect(sources(contexts)).toEqual({ "ActionPrediction", "Action" })
end)

it("matches each of two unresolved same-ID candidates to its own receipt", function()
	local actor: StateUtils.Actor = StateUtils.actor("Caster")
	local contexts: { Types.PresentationContext } = {}
	local port: PredictionUtils.Port = install({ cast("Cast", contexts) })

	local first: PredictionUtils.Start = PredictionUtils.admit(port, actor.view, "Fireball", { aim = 1 })
	local second: PredictionUtils.Start = PredictionUtils.admit(port, actor.view, "Fireball", { aim = 2 })
	task.wait()
	PredictionUtils.started(actor.actions, "Fireball", 10)
	PredictionUtils.outcome(port, actor.view, "Fireball", second, "Accepted", 10)
	PredictionUtils.started(actor.actions, "Fireball", 11)
	task.wait()
	expect(#contexts).toBe(2)
	PredictionUtils.outcome(port, actor.view, "Fireball", first, "Accepted", 11)
	task.wait()
	expect(sources(contexts)).toEqual({ "ActionPrediction", "ActionPrediction" })
end)

it("releases a permanently ambiguous Start after the bounded window, accepting a possible duplicate", function()
	local actor: StateUtils.Actor = StateUtils.actor("Caster")
	local contexts: { Types.PresentationContext } = {}
	local port: PredictionUtils.Port = install({ cast("Cast", contexts) })

	local start: PredictionUtils.Start = PredictionUtils.admit(port, actor.view, "Fireball", { aim = 1 })
	task.wait()
	PredictionUtils.outcome(port, actor.view, "Fireball", start, "Unknown", nil, "CommandTimedOut")
	PredictionUtils.started(actor.actions, "Fireball", 4)
	PredictionUtils.advance(port, WINDOW_SECONDS - 0.01)
	task.wait()
	expect(#contexts).toBe(1)
	PredictionUtils.advance(port, 0.01)
	task.wait()
	expect(sources(contexts)).toEqual({ "ActionPrediction", "Action" })

	PredictionUtils.outcome(port, actor.view, "Fireball", start, "Accepted", 4)
	task.wait()
	expect(contexts[1]:IsActive()).toBe(true)
	expect(contexts[2]:IsActive()).toBe(true)
	expect(#contexts).toBe(2)
end)

it("never defers across ActorView identities or carries a retired view's attempt to its same-ID replacement", function()
	local caster: StateUtils.Actor = StateUtils.actor("Caster")
	local other: StateUtils.Actor = StateUtils.actor("Other")
	local contexts: { Types.PresentationContext } = {}
	local port: PredictionUtils.Port = install({ cast("Cast", contexts) })

	PredictionUtils.admit(port, caster.view, "Fireball", { aim = 1 })
	task.wait()
	PredictionUtils.started(other.actions, "Fireball", 1)
	task.wait()
	expect(sources(contexts)).toEqual({ "ActionPrediction", "Action" })

	Actors.Remove(caster.view)
	local replacement: StateUtils.Actor = StateUtils.actor("Caster")
	PredictionUtils.started(replacement.actions, "Fireball", 1)
	task.wait()
	expect(#contexts).toBe(3)
	expect(contexts[3].actor).toBe(replacement.view)
end)

it("does not defer for a candidate whose estimate created no preview", function()
	local actor: StateUtils.Actor = StateUtils.actor("Caster")
	local contexts: { Types.PresentationContext } = {}

	local port: PredictionUtils.Port = install({ cast("Cast", contexts) }, {
		Fireball = {
			canPredictStart = function(): boolean?
				return false
			end,
		},
	})

	PredictionUtils.admit(port, actor.view, "Fireball", { aim = 1 })
	task.wait()
	PredictionUtils.started(actor.actions, "Fireball", 4)
	task.wait()
	expect(sources(contexts)).toEqual({ "Action" })
end)

it("expires an unmatched tombstone after the I5 outcome horizon", function()
	local actor: StateUtils.Actor = StateUtils.actor("Caster")
	local contexts: { Types.PresentationContext } = {}
	local port: PredictionUtils.Port = install({ cast("Burst", contexts, true) })

	PredictionUtils.admit(port, actor.view, "Fireball", { aim = 1 })
	task.wait()
	PredictionUtils.advance(port, RETENTION_SECONDS)
	PredictionUtils.started(actor.actions, "Fireball", 4)
	task.wait()
	expect(sources(contexts)).toEqual({ "ActionPrediction", "Action" })
end)

it("bounds deferred authoritative entries and delivers past the limit instead of holding them", function()
	local actor: StateUtils.Actor = StateUtils.actor("Caster")
	local contexts: { Types.PresentationContext } = {}
	local port: PredictionUtils.Port = install({ cast("Cast", contexts) })

	PredictionUtils.admit(port, actor.view, "Fireball", { aim = 1 })
	task.wait()

	for sequenceId: number = 1, 33 do
		PredictionUtils.started(actor.actions, "Fireball", sequenceId)
	end

	task.wait()
	expect(#contexts).toBe(2)
	PredictionUtils.advance(port, WINDOW_SECONDS)
	task.wait()
	expect(#contexts).toBe(34)
end)

it("drops deferred entries for a retired Actor without creating them later", function()
	local actor: StateUtils.Actor = StateUtils.actor("Caster")
	local contexts: { Types.PresentationContext } = {}
	local port: PredictionUtils.Port = install({ cast("Cast", contexts) })

	PredictionUtils.admit(port, actor.view, "Fireball", { aim = 1 })
	task.wait()
	PredictionUtils.started(actor.actions, "Fireball", 4)
	Actors.Remove(actor.view)
	PredictionUtils.advance(port, WINDOW_SECONDS)
	task.wait()
	expect(#contexts).toBe(1)
	expect(contexts[1]:IsActive()).toBe(false)
end)

it("keeps a deferred Start waiting while another same-ID candidate is still unresolved", function()
	local actor: StateUtils.Actor = StateUtils.actor("Caster")
	local contexts: { Types.PresentationContext } = {}
	local port: PredictionUtils.Port = install({ cast("Cast", contexts) })

	local first: PredictionUtils.Start = PredictionUtils.admit(port, actor.view, "Fireball", { aim = 1 })
	local second: PredictionUtils.Start = PredictionUtils.admit(port, actor.view, "Fireball", { aim = 2 })
	task.wait()
	PredictionUtils.started(actor.actions, "Fireball", 10)
	PredictionUtils.outcome(port, actor.view, "Fireball", first, "Rejected")
	task.wait()
	expect(#contexts).toBe(2)
	PredictionUtils.outcome(port, actor.view, "Fireball", second, "Accepted", 10)
	task.wait()
	expect(sources(contexts)).toEqual({ "ActionPrediction", "ActionPrediction" })
end)

it("releases the remaining deferred Start once its only candidate is matched and retired", function()
	local actor: StateUtils.Actor = StateUtils.actor("Caster")
	local contexts: { Types.PresentationContext } = {}
	local port: PredictionUtils.Port = install({ cast("Burst", contexts, true) })

	local start: PredictionUtils.Start = PredictionUtils.admit(port, actor.view, "Fireball", { aim = 1 })
	task.wait()
	PredictionUtils.started(actor.actions, "Fireball", 6)
	PredictionUtils.started(actor.actions, "Fireball", 5)
	PredictionUtils.outcome(port, actor.view, "Fireball", start, "Accepted", 6)
	task.wait()
	expect(sources(contexts)).toEqual({ "ActionPrediction", "Action" })
	expect(contexts[2].entry).toMatchObject({ action = { sequenceId = 5 } })
end)

it("discards deferred Starts and pending attempts when the runtime shuts down", function()
	local actor: StateUtils.Actor = StateUtils.actor("Caster")
	local contexts: { Types.PresentationContext } = {}
	local port: PredictionUtils.Port = install({ cast("Cast", contexts) })

	PredictionUtils.admit(port, actor.view, "Fireball", { aim = 1 })
	task.wait()
	PredictionUtils.started(actor.actions, "Fireball", 4)
	StateUtils.reset()
	PredictionUtils.advance(port, WINDOW_SECONDS)
	task.wait()
	expect(#contexts).toBe(1)
	expect(contexts[1]:IsActive()).toBe(false)
end)

it("stops treating an unresolved live prediction as a candidate after the I5 outcome horizon", function()
	local actor: StateUtils.Actor = StateUtils.actor("Caster")
	local contexts: { Types.PresentationContext } = {}
	local port: PredictionUtils.Port = install({ cast("Cast", contexts) })

	local start: PredictionUtils.Start = PredictionUtils.admit(port, actor.view, "Fireball", { aim = 1 })
	task.wait()
	PredictionUtils.outcome(port, actor.view, "Fireball", start, "Unknown", nil, "CommandTimedOut")
	PredictionUtils.advance(port, RETENTION_SECONDS)
	PredictionUtils.started(actor.actions, "Fireball", 9)
	task.wait()
	expect(sources(contexts)).toEqual({ "ActionPrediction", "Action" })
	expect(contexts[1]:IsActive()).toBe(true)
end)

it("releases a held Start when the horizon makes its only candidate stale", function()
	local actor: StateUtils.Actor = StateUtils.actor("Caster")
	local contexts: { Types.PresentationContext } = {}
	local port: PredictionUtils.Port = install({ cast("Cast", contexts) })

	PredictionUtils.admit(port, actor.view, "Fireball", { aim = 1 })
	task.wait()
	PredictionUtils.advance(port, RETENTION_SECONDS - 0.1)
	PredictionUtils.started(actor.actions, "Fireball", 9)
	PredictionUtils.advance(port, 0.1)
	task.wait()
	expect(sources(contexts)).toEqual({ "ActionPrediction", "Action" })
end)
