--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local afterEach: any = JestGlobals.afterEach
local Types = require(KRF.client.Presentation.types)
local Events = require(KRF.client.Presentation.PresentationEvents)
local Runtime = require(KRF.client.Presentation.PresentationRuntime)
local Registry = require(KRF.client.Presentation.PresentationRegistry)
local ActorTypes = require(KRF.client.Actor.types)
local ActorView = require(KRF.client.Actor.ActorView)
local DomainView = require(KRF.client.Actor.DomainView)
local Actors = require(KRF.client.Actor.utils.ActorViewRegistryState)
local Hints = require(KRF.client.Networking.utils.HintRuntimeState)

local owners: { ActorTypes.ActorViewOwner } = {}
local shutdown: (() -> ())? = nil

afterEach(function()
	if shutdown ~= nil then
		shutdown()
		shutdown = nil
	end

	Actors.Reset()

	for _, owner in owners do
		owner:Destroy()
	end

	table.clear(owners)
end)

local function actor(id: string): (ActorTypes.ActorView, ActorTypes.DomainViewOwner, ActorTypes.DomainViewOwner)
	local actions: ActorTypes.DomainViewOwner =
		assert(DomainView.new("KRF.Actions", {}, { "Started", "Ended", "Interrupted" }))

	local tags: ActorTypes.DomainViewOwner =
		assert(DomainView.new("KRF.Tags", {}, { "Added", "Removed", "Refreshed", "Expired" }))

	local owner: ActorTypes.ActorViewOwner =
		assert(ActorView.new(id, nil, { ["KRF.Actions"] = actions, ["KRF.Tags"] = tags }))

	table.insert(owners, owner)
	assert(Actors.Install(owner.view))

	return owner.view, actions, tags
end

local function install(event: Types.PresentationEventDescriptor, create: (Types.PresentationContext) -> ()): ()
	local catalog: Types.PresentationCatalog =
		assert(Registry.Prepare({ { id = "Test", entry = { event = event, id = "Origin" }, create = create } }))

	shutdown = assert(Runtime.Install(catalog))
end

it("matches implicit Action activation separately from explicit Action ids and other Actors", function()
	local origin: ActorTypes.ActorView, actions: ActorTypes.DomainViewOwner = actor("Origin")
	local other: ActorTypes.ActorView, otherActions: ActorTypes.DomainViewOwner = actor("Other")
	local received: { string } = {}

	install(Events.Action.Started, function(context: Types.PresentationContext)
		context:On(Events.Action.Ended, function(event: Types.ActionEntryEvent)
			expect(event.actor).toBe(origin)
			expect(event.action.sequenceId).toBe(7)
			table.insert(received, "activation")
		end)

		context:On(Events.Action.Ended, "Origin", function(event: Types.ActionEntryEvent)
			table.insert(received, "id:" .. tostring(event.action.sequenceId))
		end)

		context:On(Events.Action.Interrupted, { id = "Origin", actor = other }, function(event: Types.ActionEntryEvent)
			expect(event.actor).toBe(other)
			table.insert(received, "other")
		end)
	end)

	actions:FireEvent("Started", table.freeze({ actionId = "Origin", sequenceId = 7 }))
	task.wait()
	actions:FireEvent("Ended", table.freeze({ actionId = "Origin", sequenceId = 8 }))
	actions:FireEvent("Ended", table.freeze({ actionId = "Origin", sequenceId = 7 }))
	otherActions:FireEvent("Ended", table.freeze({ actionId = "Origin", sequenceId = 7 }))
	otherActions:FireEvent("Interrupted", table.freeze({ actionId = "Origin", sequenceId = 9 }))
	task.wait()
	table.sort(received)
	expect(received).toEqual({ "activation", "id:7", "id:8", "other" })
end)

it("uses original Tag ids and explicit cross-family ids without changing the context Actor", function()
	local origin: ActorTypes.ActorView, _actions: ActorTypes.DomainViewOwner, tags: ActorTypes.DomainViewOwner =
		actor("Origin")

	local other: ActorTypes.ActorView, _otherActions: ActorTypes.DomainViewOwner, otherTags: ActorTypes.DomainViewOwner =
		actor("Other")

	local received: { string } = {}

	install(Events.Tag.Added, function(context: Types.PresentationContext)
		context:On(Events.Tag.Removed, function(event: Types.TagEntryEvent)
			expect(table.isfrozen(event)).toBe(true)
			table.insert(received, event.tagId)
		end)

		context:On(Events.Tag.Refreshed, { id = "OtherTag", actor = other }, function(event: Types.TagEntryEvent)
			expect(context.actor).toBe(origin)
			expect(event.actor).toBe(other)
			table.insert(received, event.tagId)
		end)
	end)

	tags:FireEvent("Added", "Origin")
	task.wait()
	tags:FireEvent("Removed", "Miss")
	tags:FireEvent("Removed", "Origin")
	otherTags:FireEvent("Removed", "Origin")
	otherTags:FireEvent("Refreshed", "OtherTag")
	task.wait()
	table.sort(received)
	expect(received).toEqual({ "Origin", "OtherTag" })
end)

it("keeps Actor-less Hints Actor-less unless a concrete Actor or Any scope is requested", function()
	local target: ActorTypes.ActorView = actor("Target")
	local received: { string } = {}
	local payload = { value = 7 }

	install(Events.Hint.Received, function(context: Types.PresentationContext)
		context:On(Events.Hint.Received, function(event: Types.HintEntryEvent)
			expect(event.actor).toBeNil()
			expect(event.payload).toBe(payload)
			table.insert(received, "default")
		end)

		context:On(Events.Hint.Received, { id = "Follow", scope = "Any" }, function(event: Types.HintEntryEvent)
			table.insert(received, if event.actor == nil then "world" else "targeted")
		end)

		context:On(Events.Hint.Received, { id = "Follow", actor = target }, function(event: Types.HintEntryEvent)
			expect(event.actor).toBe(target)
			table.insert(received, "override")
		end)
	end)

	Hints.Notify({ hintId = "Origin" })
	task.wait()
	Hints.Notify({ hintId = "Origin", payload = payload })
	Hints.Notify({ hintId = "Follow", payload = payload })
	Hints.Notify({ hintId = "Follow", actorView = target, payload = payload })
	task.wait()
	table.sort(received)
	expect(received).toEqual({ "default", "override", "targeted", "world" })
end)
