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
local Actors: ActorTypes.ActorViewRegistryOwner = require(KRF.client.Actor.utils.ActorViewRegistryState)
local Hints = require(KRF.client.Networking.utils.HintRuntimeState)
local Subscriptions = require(KRF.client.Presentation.utils.PresentationSubscriptions)
local StateUtils = require(script.Parent.Utils.PresentationStateTestUtils)

afterEach(function()
	StateUtils.reset()
end)

local function origin(create: (Types.PresentationContext) -> (), readiness: StateUtils.Readiness): ()
	StateUtils.install({
		{ id = "Watcher", entry = { event = Events.Hint.Received, id = "Origin" }, create = create },
	}, readiness)
end

it("delivers the current Tag snapshot first and then only canonical Tag changes", function()
	local actor: StateUtils.Actor = StateUtils.actor("Burner", { Other = { stackCount = 1 } })

	local readiness: StateUtils.Readiness = StateUtils.readiness()
	readiness.ready[actor.view] = true

	local received: { ActorTypes.ActiveTagSnapshot | false } = {}

	origin(function(context: Types.PresentationContext)
		context:Watch(States.Tag.Active, "Burning", function(tag: ActorTypes.ActiveTagSnapshot?)
			local observed: ActorTypes.ActiveTagSnapshot | false = if tag ~= nil then tag else false
			table.insert(received, observed)
		end)
	end, readiness)

	Hints.Notify({ hintId = "Origin", actorView = actor.view })
	task.wait()
	expect(received).toEqual({ false })
	StateUtils.commit(actor.tags, { Other = { stackCount = 1 }, Burning = { stackCount = 1 } })
	task.wait()
	StateUtils.commit(actor.tags, { Other = { stackCount = 2 }, Burning = { stackCount = 1 } })
	task.wait()
	expect(received).toEqual({ false, { tagId = "Burning", stackCount = 1 } })
	StateUtils.commit(actor.tags, { Burning = { stackCount = 3 } })
	task.wait()
	StateUtils.commit(actor.tags, { Burning = { stackCount = 3, expiresAt = math.huge } })
	task.wait()
	StateUtils.commit(actor.tags, {})
	task.wait()

	expect(received).toEqual({
		false,
		{ tagId = "Burning", stackCount = 1 },
		{ tagId = "Burning", stackCount = 3 },
		{ tagId = "Burning", stackCount = 3, remainingDuration = math.huge },
		false,
	})
end)

it("resamples before delivery so queued and initial observations coalesce to the latest state", function()
	local actor: StateUtils.Actor = StateUtils.actor("Burner")

	local readiness: StateUtils.Readiness = StateUtils.readiness()
	readiness.ready[actor.view] = true

	local received: { number } = {}

	origin(function(context: Types.PresentationContext)
		context:Watch(States.Tag.Active, "Burning", function(tag: ActorTypes.ActiveTagSnapshot?)
			table.insert(received, if tag ~= nil then tag.stackCount else 0)
		end)

		StateUtils.commit(actor.tags, { Burning = { stackCount = 1 } })
		StateUtils.commit(actor.tags, { Burning = { stackCount = 2 } })
	end, readiness)

	Hints.Notify({ hintId = "Origin", actorView = actor.view })
	task.wait()
	expect(received).toEqual({ 2 })

	for stacks: number = 3, 5 do
		StateUtils.commit(actor.tags, { Burning = { stackCount = stacks } })
	end

	task.wait()
	expect(received).toEqual({ 2, 5 })
end)

it("compares canonical Resource anchors rather than locally projected regeneration", function()
	local anchor = { anchorValue = 10, anchorTime = 0, min = 0, max = 1000000, regenRate = 1 }
	local actor: StateUtils.Actor = StateUtils.actor("Caster", nil, nil, { Mana = anchor })

	local readiness: StateUtils.Readiness = StateUtils.readiness()
	readiness.ready[actor.view] = true

	local received: { ActorTypes.ResourceSnapshot | false } = {}

	origin(function(context: Types.PresentationContext)
		context:Watch(States.Resource.Current, "Mana", function(resource: ActorTypes.ResourceSnapshot?)
			local observed: ActorTypes.ResourceSnapshot | false = if resource ~= nil then resource else false
			table.insert(received, observed)
		end)
	end, readiness)

	Hints.Notify({ hintId = "Origin", actorView = actor.view })
	task.wait()
	expect(#received).toBe(1)
	local first: any = received[1]
	expect(first.resourceId).toBe("Mana")
	expect(first.max).toBe(1000000)
	task.wait(0.05)
	StateUtils.commit(actor.resources, { Mana = table.clone(anchor), Stamina = anchor })
	task.wait()
	expect(#received).toBe(1)

	StateUtils.commit(
		actor.resources,
		{ Mana = { anchorValue = 5, anchorTime = 0, min = 0, max = 1000000, regenRate = 1 } }
	)

	task.wait()
	expect(#received).toBe(2)
	StateUtils.commit(actor.resources, { Mana = { anchorValue = 5, anchorTime = 0, min = 0, max = 1000000 } })
	task.wait()
	expect(#received).toBe(3)
	expect((received[3] :: any).regenRate).toBeNil()
	StateUtils.commit(actor.resources, {})
	task.wait()
	expect(received[4]).toBe(false)
end)

it("watches only the originating Action activation", function()
	local actor: StateUtils.Actor = StateUtils.actor("Caster", nil, { [7] = "Charge", [8] = "Charge" })

	local readiness: StateUtils.Readiness = StateUtils.readiness()
	readiness.ready[actor.view] = true

	local received: { ActorTypes.ActionSnapshot | false } = {}

	StateUtils.install({
		{
			id = "Charge",
			entry = { event = Events.Action.Started, id = "Charge" },
			create = function(context: Types.PresentationContext)
				context:Watch(States.Action.Active, function(action: ActorTypes.ActionSnapshot?)
					local observed: ActorTypes.ActionSnapshot | false = if action ~= nil then action else false
					table.insert(received, observed)
				end)
			end,
		},
	}, readiness)

	actor.actions:FireEvent("Started", table.freeze({ actionId = "Charge", sequenceId = 7 }))
	task.wait()
	expect(received).toEqual({ { actionId = "Charge", sequenceId = 7 } })
	StateUtils.commit(actor.actions, { [7] = "Charge" })
	task.wait()
	expect(#received).toBe(1)
	StateUtils.commit(actor.actions, {})
	task.wait()
	expect(received).toEqual({ { actionId = "Charge", sequenceId = 7 }, false })
end)

it("tracks Model pointers independently of replicated-state readiness", function()
	local actor: StateUtils.Actor = StateUtils.actor("Mover")
	local readiness: StateUtils.Readiness = StateUtils.readiness()
	local received: { Model | false } = {}
	local first: Model = Instance.new("Model")
	local second: Model = Instance.new("Model")

	origin(function(context: Types.PresentationContext)
		context:Watch(States.Actor.Model, function(model: Model?)
			local observed: Model | false = if model ~= nil then model else false
			table.insert(received, observed)
		end)
	end, readiness)

	Hints.Notify({ hintId = "Origin", actorView = actor.view })
	task.wait()
	expect(received).toEqual({ false })

	local function rebind(model: Model?): ()
		local previous: Model? = actor.view:GetModel()
		actor.owner:InstallModel(model)
		actor.owner:NotifyModelChanged(previous, model)
		task.wait()
	end

	rebind(first)
	rebind(second)
	rebind(nil)
	expect(received).toEqual({ false, first, second, false })
	first:Destroy()
	second:Destroy()
end)

it("pauses state Watches while stale, defers new initial delivery and refreshes both from ready truth", function()
	local actor: StateUtils.Actor = StateUtils.actor("Burner", { Burning = { stackCount = 1 } })

	local readiness: StateUtils.Readiness = StateUtils.readiness()
	readiness.ready[actor.view] = true

	local earlier: { number } = {}
	local later: { number } = {}
	local context: Types.PresentationContext? = nil

	origin(function(current: Types.PresentationContext)
		context = current

		current:Watch(States.Tag.Active, "Burning", function(tag: ActorTypes.ActiveTagSnapshot?)
			table.insert(earlier, if tag ~= nil then tag.stackCount else 0)
		end)
	end, readiness)

	Hints.Notify({ hintId = "Origin", actorView = actor.view })
	task.wait()
	expect(earlier).toEqual({ 1 })
	StateUtils.setReady(readiness, actor.view, false)
	StateUtils.commit(actor.tags, { Burning = { stackCount = 2 } })
	assert(context ~= nil, "Expected Watch origin")

	context:Watch(States.Tag.Active, "Burning", function(tag: ActorTypes.ActiveTagSnapshot?)
		table.insert(later, if tag ~= nil then tag.stackCount else 0)
	end)

	task.wait()
	expect(earlier).toEqual({ 1 })
	expect(later).toEqual({})
	StateUtils.commit(actor.tags, { Burning = { stackCount = 3 } })
	StateUtils.setReady(readiness, actor.view, true)
	task.wait()
	expect(earlier).toEqual({ 1, 3 })
	expect(later).toEqual({ 3 })
end)

it(
	"rejects malformed registrations, Actor-less origins and missing Action origins without a global fallback",
	function()
		local actor: StateUtils.Actor = StateUtils.actor("Burner")

		local readiness: StateUtils.Readiness = StateUtils.readiness()
		readiness.ready[actor.view] = true

		local failures: { [string]: string } = {}
		local retired: Types.PresentationContext? = nil

		local function attempt(label: string, context: any, ...: any): ()
			local success: boolean, failure: any = pcall(context.Watch, context, ...)
			failures[label] = if success then "Accepted" else tostring(failure)
		end

		origin(function(context: Types.PresentationContext)
			local entry: Types.PresentationEntry = context.entry
			assert(entry.source == "Hint", "Expected Hint origin")
			local callback = function() end

			if entry.actor == nil then
				attempt("Actorless", context, States.Tag.Active, "Burning", callback)
				attempt("ActorlessModel", context, States.Actor.Model, callback)
				retired = context

				return
			end

			attempt("Fabricated", context, { source = "Tag", state = "Active" }, "Burning", callback)
			attempt("Event", context, Events.Tag.Added, "Burning", callback)
			attempt("MissingId", context, States.Tag.Active, callback)
			attempt("EmptyId", context, States.Resource.Current, "", callback)
			attempt("Callback", context, States.Tag.Active, "Burning", "Callback")
			attempt("Extra", context, States.Actor.Model, callback, "extra")
			attempt("ActionOrigin", context, States.Action.Active, callback)
			attempt("Valid", context, States.Actor.Model, callback)
			actor.owner:InstallUnavailable()
			attempt("Unavailable", context, States.Actor.Model, callback)
		end, readiness)

		Hints.Notify({ hintId = "Origin", actorView = actor.view })
		Hints.Notify({ hintId = "Origin" })
		task.wait()
		expect(failures.Valid).toBe("Accepted")
		expect(failures.Fabricated).toMatch("UnknownStateDescriptor")
		expect(failures.Event).toMatch("UnknownStateDescriptor")
		expect(failures.MissingId).toMatch("InvalidArguments")
		expect(failures.EmptyId).toMatch("IdInvalid")
		expect(failures.Callback).toMatch("CallbackInvalid")
		expect(failures.Extra).toMatch("InvalidArguments")
		expect(failures.ActionOrigin).toMatch("OriginActionMissing")
		expect(failures.Unavailable).toMatch("ActorUnavailable")
		expect(failures.ActorlessModel).toMatch("ActorMissing")
		expect(failures.Actorless).toMatch("ActorMissing")
		assert(retired ~= nil, "Expected Actor-less origin")
		retired:Finish()
		local handle: SignalTypes.Connection = (retired :: any):Watch("Invalid")
		handle:Disconnect()
		handle:Disconnect()
	end
)

it("owns Watch connections through disconnect, Finish and Actor retirement and isolates callback faults", function()
	local actor: StateUtils.Actor = StateUtils.actor("Burner")

	local readiness: StateUtils.Readiness = StateUtils.readiness()
	readiness.ready[actor.view] = true

	local contexts: { Types.PresentationContext } = {}
	local handles: { SignalTypes.Connection } = {}

	local received: { [string]: number } =
		{ Early = 0, Handle = 0, Finish = 0, Fault = 0, ObjectFault = 0, Survivor = 0 }

	origin(function(context: Types.PresentationContext)
		local entry: Types.PresentationEntry = context.entry
		assert(entry.source == "Hint", "Expected Hint origin")
		local label: string = entry.payload
		table.insert(contexts, context)

		local handle: SignalTypes.Connection = context:Watch(
			States.Tag.Active,
			"Burning",
			function(tag: ActorTypes.ActiveTagSnapshot?)
				received[label] += 1

				if label == "Fault" and tag ~= nil then
					error("Expected Watch failure")
				elseif label == "ObjectFault" and tag ~= nil then
					error({}, 0)
				end
			end
		)

		if label == "Early" then
			handle:Disconnect()
		end

		table.insert(handles, handle)
	end, readiness)

	for _, label: string in { "Handle", "Finish", "Fault", "ObjectFault", "Survivor", "Early" } do
		Hints.Notify({ hintId = "Origin", actorView = actor.view, payload = label })
	end

	task.wait()
	expect(received).toEqual({ Early = 0, Handle = 1, Finish = 1, Fault = 1, ObjectFault = 1, Survivor = 1 })
	handles[1]:Disconnect()
	contexts[2]:Finish()
	StateUtils.commit(actor.tags, { Burning = { stackCount = 1 } })
	task.wait()
	expect(received).toEqual({ Early = 0, Handle = 1, Finish = 1, Fault = 2, ObjectFault = 2, Survivor = 2 })
	expect(contexts[3]:IsActive()).toBe(false)
	expect(contexts[4]:IsActive()).toBe(false)
	expect(contexts[5]:IsActive()).toBe(true)
	Actors.Remove(actor.view)
	expect(contexts[5]:IsActive()).toBe(false)
	task.wait()
	expect(received.Survivor).toBe(2)
end)

it("lets a newer delivery start while an earlier Watch callback is still yielding", function()
	local actor: StateUtils.Actor = StateUtils.actor("Burner")

	local readiness: StateUtils.Readiness = StateUtils.readiness()
	readiness.ready[actor.view] = true

	local gate: BindableEvent = Instance.new("BindableEvent")
	local started: { number } = {}
	local finished: { number } = {}

	origin(function(context: Types.PresentationContext)
		context:Watch(States.Tag.Active, "Burning", function(tag: ActorTypes.ActiveTagSnapshot?)
			local stacks: number = if tag ~= nil then tag.stackCount else 0
			table.insert(started, stacks)
			gate.Event:Wait()
			table.insert(finished, stacks)
		end)
	end, readiness)

	Hints.Notify({ hintId = "Origin", actorView = actor.view })
	task.wait()
	StateUtils.commit(actor.tags, { Burning = { stackCount = 1 } })
	task.wait()
	expect(started).toEqual({ 0, 1 })
	expect(finished).toEqual({})
	gate:Fire()
	task.wait()
	table.sort(finished)
	expect(finished).toEqual({ 0, 1 })
	gate:Destroy()
end)

it("retires a state-backed owner with its condition through owned cleanup rather than a final Watch nil", function()
	local actor: StateUtils.Actor = StateUtils.actor("Burner", { Burning = { stackCount = 1 } })

	local readiness: StateUtils.Readiness = StateUtils.readiness()
	readiness.ready[actor.view] = true

	local received: { number } = {}
	local cleanups: number = 0

	StateUtils.install({
		{
			id = "Aura",
			entry = { state = States.Tag.Active, id = "Burning" },
			create = function(context: Types.PresentationContext)
				context:Own(function()
					cleanups += 1
				end)

				context:Watch(States.Tag.Active, "Burning", function(tag: ActorTypes.ActiveTagSnapshot?)
					table.insert(received, if tag ~= nil then tag.stackCount else 0)
				end)
			end,
		},
	}, readiness)

	task.wait()
	expect(received).toEqual({ 1 })
	StateUtils.commit(actor.tags, {})
	task.wait()
	expect(cleanups).toBe(1)
	expect(received[1]).toBe(1)
	expect(#received <= 2).toBe(true)
end)

it("reconnects at the owning typed view when a missing built-in domain joins later", function()
	local actor: StateUtils.Actor = StateUtils.actor("Burner")

	local readiness: StateUtils.Readiness = StateUtils.readiness()
	readiness.ready[actor.view] = true

	local received: { number } = {}

	local withoutTags: { [string]: ActorTypes.DomainViewOwner } =
		{ ["KRF.Actions"] = actor.actions, ["KRF.Resources"] = actor.resources }

	actor.owner:InstallDomains(withoutTags)

	origin(function(context: Types.PresentationContext)
		context:Watch(States.Tag.Active, "Burning", function(tag: ActorTypes.ActiveTagSnapshot?)
			table.insert(received, if tag ~= nil then tag.stackCount else 0)
		end)
	end, readiness)

	Hints.Notify({ hintId = "Origin", actorView = actor.view })
	task.wait()
	expect(received).toEqual({ 0 })
	actor.tags:InstallState(table.freeze({ Burning = table.freeze({ stackCount = 4 }) }))

	local membership: ActorTypes.DomainMembershipChange? = actor.owner:InstallDomains({
		["KRF.Actions"] = actor.actions,
		["KRF.Resources"] = actor.resources,
		["KRF.Tags"] = actor.tags,
	})

	actor.owner:NotifyDomainsChanged(assert(membership, "Expected Tags membership"))
	task.wait()
	expect(received).toEqual({ 0, 4 })
end)

it("samples the current private Action association so a later adoption changes the watched activation", function()
	local actor: StateUtils.Actor = StateUtils.actor("Caster", nil, { [7] = "Charge", [8] = "Charge" })

	local association: Types.PresentationActionAssociation? =
		{ actor = actor.view, actionId = "Charge", sequenceId = 7 }

	local hintOrigin: Types.HintEntryEvent =
		{ source = "Hint", event = "Received", actor = actor.view, hintId = "Origin" }

	local received: { number } = {}

	local _on, watch, stop = Subscriptions.New("Adoption", hintOrigin, {
		IsActive = function(): boolean
			return true
		end,
		GetActionAssociation = function(): Types.PresentationActionAssociation?
			return association
		end,
		Fail = function(): ()
			error("Unexpected Watch failure")
		end,
	}, {
		IsEligible = function(): boolean
			return true
		end,
		TrackActor = function(): () -> ()
			return function(): () end
		end,
		IsStateReady = function(): boolean
			return true
		end,
		ObserveReadiness = function(): () -> ()
			return function(): () end
		end,
	})

	local unsafeWatch: any = watch

	unsafeWatch(nil, States.Action.Active, function(action: ActorTypes.ActionSnapshot?)
		table.insert(received, if action ~= nil then action.sequenceId else 0)
	end)

	task.wait()
	association = { actor = actor.view, actionId = "Charge", sequenceId = 8 }
	StateUtils.commit(actor.actions, { [7] = "Charge", [8] = "Charge" })
	task.wait()
	association = nil
	StateUtils.commit(actor.actions, { [7] = "Charge", [8] = "Charge" })
	task.wait()
	expect(received).toEqual({ 7, 8, 0 })
	stop()
end)
