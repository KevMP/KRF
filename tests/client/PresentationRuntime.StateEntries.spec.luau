--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local afterEach: any = JestGlobals.afterEach
local ActorTypes = require(KRF.client.Actor.types)
local NetworkingTypes = require(KRF.client.Networking.types)
local Types = require(KRF.client.Presentation.types)
local Events = require(KRF.client.Presentation.PresentationEvents)
local States = require(KRF.client.Presentation.PresentationStates)
local Registry = require(KRF.client.Presentation.PresentationRegistry)
local Runtime = require(KRF.client.Presentation.PresentationRuntime)
local Actors: ActorTypes.ActorViewRegistryOwner = require(KRF.client.Actor.utils.ActorViewRegistryState)
local Hints = require(KRF.client.Networking.utils.HintRuntimeState)
local StateUtils = require(script.Parent.Utils.PresentationStateTestUtils)

local stopRuntime: (() -> ())? = nil

afterEach(function()
	if stopRuntime ~= nil then
		stopRuntime()
		stopRuntime = nil
	end

	StateUtils.reset()
end)

local function aura(id: string, tagId: string, contexts: { Types.PresentationContext }): Types.PresentationDefinition
	return {
		id = id,
		entry = { state = States.Tag.Active, id = tagId },
		create = function(context: Types.PresentationContext)
			table.insert(contexts, context)
		end,
	}
end

it("creates one instance from a Tag that is already active at installation without a live Added entry", function()
	local actor: StateUtils.Actor = StateUtils.actor("Burner", { Burning = { stackCount = 2 } })

	local readiness: StateUtils.Readiness = StateUtils.readiness()
	readiness.ready[actor.view] = true

	local contexts: { Types.PresentationContext } = {}
	local bursts: number = 0

	StateUtils.install({
		aura("Aura", "Burning", contexts),
		{
			id = "Burst",
			entry = { event = Events.Tag.Added, id = "Burning" },
			create = function()
				bursts += 1
			end,
		},
	}, readiness)

	task.wait()
	expect(#contexts).toBe(1)
	expect(bursts).toBe(0)
	local context: Types.PresentationContext = contexts[1]
	expect(context.actor).toBe(actor.view)
	local entry: Types.PresentationEntry = context.entry
	expect(table.isfrozen(entry)).toBe(true)
	assert(entry.source == "State" and entry.kind == "Tag", "Expected a Tag state entry")
	expect(entry.actor).toBe(actor.view)
	expect(entry.tagId).toBe("Burning")
	expect(entry.tag).toEqual({ tagId = "Burning", stackCount = 2 })
	expect(context:IsActive()).toBe(true)
end)

it("follows observed Tag presence: refreshes keep one aura, absence retires it once, presence recreates it", function()
	local actor: StateUtils.Actor = StateUtils.actor("Burner")
	local readiness: StateUtils.Readiness = StateUtils.readiness()
	local contexts: { Types.PresentationContext } = {}
	local cleanups: number = 0

	StateUtils.install({
		{
			id = "Aura",
			entry = { state = States.Tag.Active, id = "Burning" },
			create = function(context: Types.PresentationContext)
				table.insert(contexts, context)

				context:Own(function()
					cleanups += 1
				end)
			end,
		},
	}, readiness)

	StateUtils.commit(actor.tags, { Burning = { stackCount = 1 } })
	task.wait()
	expect(#contexts).toBe(0)
	StateUtils.setReady(readiness, actor.view, true)
	task.wait()
	expect(#contexts).toBe(1)
	StateUtils.commit(actor.tags, { Burning = { stackCount = 2 } })
	StateUtils.commit(actor.tags, { Burning = { stackCount = 2, expiresAt = 50 } })
	task.wait()
	expect(#contexts).toBe(1)
	expect(contexts[1]:IsActive()).toBe(true)
	StateUtils.commit(actor.tags, {})
	task.wait()
	expect(contexts[1]:IsActive()).toBe(false)
	expect(cleanups).toBe(1)
	StateUtils.commit(actor.tags, {})
	task.wait()
	expect(cleanups).toBe(1)
	StateUtils.commit(actor.tags, { Burning = { stackCount = 1 } })
	task.wait()
	expect(#contexts).toBe(2)
	expect(contexts[2]).never.toBe(contexts[1])
	expect(contexts[2]:IsActive()).toBe(true)
end)

it("coalesces a Tag toggle that completes before reconciliation instead of inventing an episode", function()
	local actor: StateUtils.Actor = StateUtils.actor("Burner", { Burning = { stackCount = 1 } })

	local readiness: StateUtils.Readiness = StateUtils.readiness()
	readiness.ready[actor.view] = true

	local contexts: { Types.PresentationContext } = {}
	StateUtils.install({ aura("Aura", "Burning", contexts) }, readiness)
	task.wait()
	StateUtils.commit(actor.tags, {})
	StateUtils.commit(actor.tags, { Burning = { stackCount = 1 } })
	task.wait()
	expect(#contexts).toBe(1)
	expect(contexts[1]:IsActive()).toBe(true)
end)

it("creates one instance per active Action sequence and retires each with its own activation", function()
	local actor: StateUtils.Actor = StateUtils.actor("Caster", nil, { [7] = "Charge", [8] = "Charge", [9] = "Other" })

	local readiness: StateUtils.Readiness = StateUtils.readiness()
	readiness.ready[actor.view] = true

	local contexts: { [number]: Types.PresentationContext } = {}
	local ended: { number } = {}

	StateUtils.install({
		{
			id = "Loop",
			entry = { state = States.Action.Active, id = "Charge" },
			create = function(context: Types.PresentationContext)
				local entry: Types.PresentationEntry = context.entry
				assert(entry.source == "State" and entry.kind == "Action", "Expected an Action state entry")
				expect(entry.actor).toBe(actor.view)
				expect(table.isfrozen(entry)).toBe(true)
				contexts[entry.action.sequenceId] = context

				context:On(Events.Action.Ended, function(event: Types.ActionEntryEvent)
					table.insert(ended, event.action.sequenceId)
				end)
			end,
		},
	}, readiness)

	task.wait()
	expect(contexts[7]).never.toBeNil()
	expect(contexts[8]).never.toBeNil()
	expect(contexts[9]).toBeNil()
	expect((contexts[7].entry :: any).action).toEqual({ actionId = "Charge", sequenceId = 7 })
	actor.actions:FireEvent("Ended", table.freeze({ actionId = "Charge", sequenceId = 8 }))
	task.wait()
	expect(ended).toEqual({ 8 })
	StateUtils.commit(actor.actions, { [8] = "Charge", [9] = "Other" })
	task.wait()
	expect(contexts[7]:IsActive()).toBe(false)
	expect(contexts[8]:IsActive()).toBe(true)
	StateUtils.commit(actor.actions, { [8] = "Charge", [9] = "Other", [10] = "Charge" })
	task.wait()
	expect(contexts[10]).never.toBeNil()
	expect(contexts[8]:IsActive()).toBe(true)
end)

it("suppresses an explicitly finished or faulted aura until absence is observed", function()
	local actor: StateUtils.Actor =
		StateUtils.actor("Burner", { Burning = { stackCount = 1 }, Frozen = { stackCount = 1 } })

	local readiness: StateUtils.Readiness = StateUtils.readiness()
	readiness.ready[actor.view] = true

	local finished: number = 0
	local faulted: number = 0

	StateUtils.install({
		{
			id = "Finisher",
			entry = { state = States.Tag.Active, id = "Burning" },
			create = function(context: Types.PresentationContext)
				finished += 1
				context:Finish()
			end,
		},
		{
			id = "Fault",
			entry = { state = States.Tag.Active, id = "Frozen" },
			create = function()
				faulted += 1
				error("Expected constructor failure")
			end,
		},
	}, readiness)

	task.wait()
	expect(finished).toBe(1)
	expect(faulted).toBe(1)
	StateUtils.commit(actor.tags, { Burning = { stackCount = 2 }, Frozen = { stackCount = 2 } })
	StateUtils.setReady(readiness, actor.view, true)
	task.wait()
	task.wait()
	expect(finished).toBe(1)
	expect(faulted).toBe(1)
	StateUtils.commit(actor.tags, {})
	task.wait()
	StateUtils.commit(actor.tags, { Burning = { stackCount = 1 }, Frozen = { stackCount = 1 } })
	task.wait()
	expect(finished).toBe(2)
	expect(faulted).toBe(2)
end)

it("suppresses a capacity-refused aura until a new observed activation", function()
	local actor: StateUtils.Actor = StateUtils.actor("Burner")

	local readiness: StateUtils.Readiness = StateUtils.readiness()
	readiness.ready[actor.view] = true

	local holders: { Types.PresentationContext } = {}
	local contexts: { Types.PresentationContext } = {}

	StateUtils.install({
		aura("Aura", "Burning", contexts),
		{
			id = "Holder",
			entry = { event = Events.Hint.Received, id = "Hold" },
			create = function(context: Types.PresentationContext)
				table.insert(holders, context)
			end,
		},
	}, readiness)

	for _ = 1, 256 do
		Hints.Notify({ hintId = "Hold" })
	end

	StateUtils.commit(actor.tags, { Burning = { stackCount = 1 } })
	task.wait()
	expect(#contexts).toBe(0)
	holders[1]:Finish()
	StateUtils.commit(actor.tags, { Burning = { stackCount = 2 } })
	task.wait()
	expect(#contexts).toBe(0)
	StateUtils.commit(actor.tags, {})
	task.wait()
	StateUtils.commit(actor.tags, { Burning = { stackCount = 1 } })
	task.wait()
	expect(#contexts).toBe(1)
end)

it("releases a reservation whose state became stale before construction and creates it once ready", function()
	local actor: StateUtils.Actor = StateUtils.actor("Burner", { Burning = { stackCount = 1 } })
	local readiness: StateUtils.Readiness = StateUtils.readiness()
	local checks: number = 0
	local observers: { StateUtils.ReadinessObserver } = {}

	local source: NetworkingTypes.ActorViewStateReadinessSource = table.freeze({
		IsStateReady = function(
			_self: NetworkingTypes.ActorViewStateReadinessSource,
			_actor: ActorTypes.ActorView
		): boolean
			checks += 1

			return checks == 1 or readiness.ready[actor.view] == true
		end,
		ObserveStateReadiness = function(
			_self: NetworkingTypes.ActorViewStateReadinessSource,
			callback: StateUtils.ReadinessObserver
		): () -> ()
			table.insert(observers, callback)

			return function() end
		end,
	})

	local contexts: { Types.PresentationContext } = {}
	stopRuntime = assert(Runtime.Install(assert(Registry.Prepare({ aura("Aura", "Burning", contexts) })), source))
	task.wait()
	expect(checks > 1).toBe(true)
	expect(#contexts).toBe(0)
	readiness.ready[actor.view] = true

	for _, observer: StateUtils.ReadinessObserver in observers do
		observer(actor.view, "Ready")
	end

	task.wait()
	expect(#contexts).toBe(1)
end)

it("retires a yielding constructor whose state disappears and still runs its owned cleanup", function()
	local actor: StateUtils.Actor = StateUtils.actor("Burner", { Burning = { stackCount = 1 } })

	local readiness: StateUtils.Readiness = StateUtils.readiness()
	readiness.ready[actor.view] = true

	local resumedActive: boolean? = nil
	local cleanups: number = 0

	StateUtils.install({
		{
			id = "Slow",
			entry = { state = States.Tag.Active, id = "Burning" },
			create = function(context: Types.PresentationContext)
				task.wait(0.05)
				resumedActive = context:IsActive()

				context:Own(function()
					cleanups += 1
				end)
			end,
		},
	}, readiness)

	task.wait()
	StateUtils.commit(actor.tags, {})
	task.wait(0.1)
	expect(resumedActive).toBe(false)
	expect(cleanups).toBe(1)
end)

it("keeps running state instances while stale and reconciles the installed truth once ready", function()
	local actor: StateUtils.Actor =
		StateUtils.actor("Burner", { Burning = { stackCount = 1 }, Frozen = { stackCount = 1 } })

	local readiness: StateUtils.Readiness = StateUtils.readiness()
	readiness.ready[actor.view] = true

	local burning: { Types.PresentationContext } = {}
	local frozen: { Types.PresentationContext } = {}
	local shocked: { Types.PresentationContext } = {}

	StateUtils.install({
		aura("Burning", "Burning", burning),
		aura("Frozen", "Frozen", frozen),
		aura("Shocked", "Shocked", shocked),
	}, readiness)

	task.wait()
	expect(#burning).toBe(1)
	expect(#frozen).toBe(1)
	StateUtils.setReady(readiness, actor.view, false)
	StateUtils.commit(actor.tags, { Burning = { stackCount = 1 }, Shocked = { stackCount = 1 } })
	task.wait()
	expect(frozen[1]:IsActive()).toBe(true)
	expect(#shocked).toBe(0)
	StateUtils.setReady(readiness, actor.view, true)
	task.wait()
	expect(#burning).toBe(1)
	expect(burning[1]:IsActive()).toBe(true)
	expect(frozen[1]:IsActive()).toBe(false)
	expect(#shocked).toBe(1)
	StateUtils.setReady(readiness, actor.view, true)
	task.wait()
	expect(#burning).toBe(1)
	expect(#shocked).toBe(1)
end)

it("retires state instances on Actor invalidation and treats an equal-id replacement as a new origin", function()
	local actor: StateUtils.Actor = StateUtils.actor("Burner", { Burning = { stackCount = 1 } })

	local readiness: StateUtils.Readiness = StateUtils.readiness()
	readiness.ready[actor.view] = true

	local contexts: { Types.PresentationContext } = {}
	StateUtils.install({ aura("Aura", "Burning", contexts) }, readiness)
	task.wait()
	expect(#contexts).toBe(1)
	Actors.Remove(actor.view)
	expect(contexts[1]:IsActive()).toBe(false)
	StateUtils.setReady(readiness, actor.view, true)
	local replacement: StateUtils.Actor = StateUtils.actor("Burner", { Burning = { stackCount = 1 } })
	StateUtils.setReady(readiness, replacement.view, true)
	task.wait()
	expect(#contexts).toBe(2)
	expect(contexts[2].actor).toBe(replacement.view)
end)

it("creates no state-backed instance without a verified readiness source", function()
	StateUtils.actor("Burner", { Burning = { stackCount = 1 } })
	local contexts: { Types.PresentationContext } = {}
	StateUtils.install({ aura("Aura", "Burning", contexts) })
	task.wait()
	expect(#contexts).toBe(0)
end)

it("stops observing readiness and retires state instances when the runtime shuts down", function()
	local actor: StateUtils.Actor = StateUtils.actor("Burner", { Burning = { stackCount = 1 } })

	local readiness: StateUtils.Readiness = StateUtils.readiness()
	readiness.ready[actor.view] = true

	local contexts: { Types.PresentationContext } = {}

	stopRuntime =
		assert(Runtime.Install(assert(Registry.Prepare({ aura("Aura", "Burning", contexts) })), readiness.source))

	task.wait()
	expect((next(readiness.observers))).never.toBeNil()
	assert(stopRuntime, "Expected runtime shutdown")()
	stopRuntime = nil
	expect(contexts[1]:IsActive()).toBe(false)
	expect((next(readiness.observers))).toBeNil()
	StateUtils.commit(actor.tags, {})
	StateUtils.commit(actor.tags, { Burning = { stackCount = 1 } })
	task.wait()
	expect(#contexts).toBe(1)
end)

it("resolves no-ID Tag subscriptions from a Tag state origin and rejects families it cannot identify", function()
	local actor: StateUtils.Actor = StateUtils.actor("Burner", { Burning = { stackCount = 1 } }, { [3] = "Charge" })

	local readiness: StateUtils.Readiness = StateUtils.readiness()
	readiness.ready[actor.view] = true

	local removed: { string } = {}
	local failures: { [string]: string } = {}

	local function attempt(label: string, context: any, ...: any): ()
		local success: boolean, failure: any = pcall(context.On, context, ...)
		failures[label] = if success then "Accepted" else tostring(failure)
	end

	StateUtils.install({
		{
			id = "Aura",
			entry = { state = States.Tag.Active, id = "Burning" },
			create = function(context: Types.PresentationContext)
				context:On(Events.Tag.Removed, function(event: Types.TagEntryEvent)
					table.insert(removed, event.tagId)
				end)

				attempt("TagResource", context, Events.Resource.Changed, function() end)
				attempt("TagAction", context, Events.Action.Ended, function() end)
			end,
		},
		{
			id = "Loop",
			entry = { state = States.Action.Active, id = "Charge" },
			create = function(context: Types.PresentationContext)
				attempt("ActionTag", context, Events.Tag.Added, function() end)
			end,
		},
	}, readiness)

	task.wait()
	actor.tags:FireEvent("Removed", "Other")
	actor.tags:FireEvent("Removed", "Burning")
	task.wait()
	expect(removed).toEqual({ "Burning" })
	expect(failures.TagResource).toMatch("OriginIdMissing")
	expect(failures.TagAction).toMatch("OriginActionMissing")
	expect(failures.ActionTag).toMatch("OriginIdMissing")
end)

it("skips construction when the reserved Tag disappears before the deferred constructor runs", function()
	local actor: StateUtils.Actor = StateUtils.actor("Burner")

	local readiness: StateUtils.Readiness = StateUtils.readiness()
	readiness.ready[actor.view] = true

	local contexts: { Types.PresentationContext } = {}
	StateUtils.install({ aura("Aura", "Burning", contexts) }, readiness)
	task.wait()
	StateUtils.commit(actor.tags, { Burning = { stackCount = 1 } })

	task.defer(function()
		StateUtils.commit(actor.tags, {})
	end)

	task.wait()
	task.wait()
	expect(#contexts).toBe(0)
	StateUtils.commit(actor.tags, { Burning = { stackCount = 1 } })
	task.wait()
	expect(#contexts).toBe(1)
end)

it("suppresses an aura retired by its own Watch fault until absence is observed", function()
	local actor: StateUtils.Actor = StateUtils.actor("Burner", { Burning = { stackCount = 1 } })

	local readiness: StateUtils.Readiness = StateUtils.readiness()
	readiness.ready[actor.view] = true

	local contexts: { Types.PresentationContext } = {}

	StateUtils.install({
		{
			id = "Fragile",
			entry = { state = States.Tag.Active, id = "Burning" },
			create = function(context: Types.PresentationContext)
				table.insert(contexts, context)

				context:Watch(States.Tag.Active, "Burning", function(tag: ActorTypes.ActiveTagSnapshot?)
					if tag ~= nil and tag.stackCount > 1 then
						error("Expected Watch failure")
					end
				end)
			end,
		},
	}, readiness)

	task.wait()
	StateUtils.commit(actor.tags, { Burning = { stackCount = 2 } })
	task.wait()
	expect(#contexts).toBe(1)
	expect(contexts[1]:IsActive()).toBe(false)
	StateUtils.commit(actor.tags, { Burning = { stackCount = 3 } })
	task.wait()
	expect(#contexts).toBe(1)
	StateUtils.commit(actor.tags, {})
	task.wait()
	StateUtils.commit(actor.tags, { Burning = { stackCount = 1 } })
	task.wait()
	expect(#contexts).toBe(2)
	expect(contexts[2]:IsActive()).toBe(true)
end)
