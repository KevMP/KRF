--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local afterEach: any = JestGlobals.afterEach
local ActorTypes = require(KRF.client.Actor.types)
local ActorView = require(KRF.client.Actor.ActorView)
local DomainView = require(KRF.client.Actor.DomainView)
local SignalTypes = require(KRF.shared.Signal.types)
local Registry = require(KRF.client.Actor.ActorViewRegistry)
local Actors = require(KRF.client.Actor.utils.ActorViewRegistryState)
local HintState = require(KRF.client.Networking.utils.HintRuntimeState)
local Types = require(KRF.client.Presentation.types)
local Events = require(KRF.client.Presentation.PresentationEvents)
local Client = require(KRF.client)
local ClientUtils = require(script.Parent.Utils.ClientTestUtils)

local owned: { ActorTypes.ActorViewOwner } = {}
local addedConnection: SignalTypes.Connection? = nil

afterEach(function()
	if addedConnection ~= nil then
		addedConnection:Disconnect()
		addedConnection = nil
	end

	Client._ResetForTests()
	Actors.Reset()

	for _, owner in owned do
		owner:Destroy()
	end

	table.clear(owned)
end)

local function installActor(id: string, domains: { [string]: ActorTypes.DomainViewOwner }): ActorTypes.ActorViewOwner
	local owner: ActorTypes.ActorViewOwner = assert(ActorView.new(id, nil, domains), "Expected valid ActorView")
	table.insert(owned, owner)
	assert(Actors.Install(owner.view), "Expected unique ActorView")

	return owner
end

local function ready(definitions: { Types.PresentationDefinition }): ()
	local fixture: ClientUtils.Fixture = ClientUtils.new()
	ClientUtils.start(fixture, { presentations = definitions })
	ClientUtils.bootstrap(fixture)
	ClientUtils.acknowledge(fixture)
	expect(fixture.result).toEqual({ success = true })
end

it("delivers all nine typed sources with exact selectors and excludes resource baselines", function()
	local actions: ActorTypes.DomainViewOwner =
		assert(DomainView.new("KRF.Actions", {}, { "Started", "Ended", "Interrupted" }), "Expected Actions DomainView")

	local tags: ActorTypes.DomainViewOwner = assert(
		DomainView.new("KRF.Tags", {}, { "Added", "Refreshed", "Removed", "Expired" }),
		"Expected Tags DomainView"
	)

	local resources: ActorTypes.DomainViewOwner =
		assert(DomainView.new("KRF.Resources", {}, {}), "Expected Resources DomainView")

	local actor: ActorTypes.ActorView = installActor("ActorBeforeStartup", {
		["KRF.Actions"] = actions,
		["KRF.Tags"] = tags,
		["KRF.Resources"] = resources,
	}).view

	local received: { [string]: { Types.PresentationContext } } = {}
	local definitions: { Types.PresentationDefinition } = {}

	local descriptors: { Types.PresentationEventDescriptor } = {
		Events.Action.Started,
		Events.Action.Ended,
		Events.Action.Interrupted,
		Events.Tag.Added,
		Events.Tag.Refreshed,
		Events.Tag.Removed,
		Events.Tag.Expired,
		Events.Resource.Changed,
		Events.Hint.Received,
	}

	for _, descriptor in descriptors do
		local id: string = descriptor.source .. "." .. descriptor.event

		table.insert(definitions, {
			id = id,
			entry = { event = descriptor, id = "Match" },
			create = function(context: Types.PresentationContext)
				local contexts: { Types.PresentationContext } = received[id] or {}

				received[id] = contexts
				table.insert(contexts, context)
			end,
		})
	end

	local unavailable: ActorTypes.ActorViewOwner = installActor("UnavailableBeforeStartup", {})
	unavailable:InstallUnavailable()
	ready(definitions)
	HintState.Notify({ hintId = "Match", actorView = unavailable.view, payload = 35 })
	Actors.Remove(unavailable.view)

	for _, event: string in { "Started", "Ended", "Interrupted" } do
		actions:FireEvent(event, table.freeze({ actionId = "Match", sequenceId = 7 }))
		actions:FireEvent(event, table.freeze({ actionId = "Other", sequenceId = 8 }))
	end

	for _, event: string in { "Added", "Refreshed", "Removed", "Expired" } do
		tags:FireEvent(event, "Match")
		tags:FireEvent(event, "Other")
	end

	local anchor = table.freeze({ anchorValue = 5, anchorTime = 0, min = 0, max = 10 })
	resources:NotifyChanged({ previous = {}, current = { Match = anchor }, source = "Baseline" })
	resources:NotifyChanged({ previous = {}, current = { Match = anchor, Other = anchor }, source = "Commit" })
	HintState.Notify({ hintId = "Match", actorView = actor, payload = 32 })
	HintState.Notify({ hintId = "Other", actorView = actor, payload = 33 })
	task.wait()

	for _, descriptor in descriptors do
		local id: string = descriptor.source .. "." .. descriptor.event
		local contexts: { Types.PresentationContext } = received[id] or {}
		expect(#contexts).toBe(1)
		local context: Types.PresentationContext = contexts[1]
		local entry: Types.PresentationEntry = context.entry
		assert(entry.source ~= "State", "Expected a live event entry")
		expect(entry.source).toBe(descriptor.source)
		expect(entry.event).toBe(descriptor.event)
		expect(context.actor).toBe(actor)
		expect(entry.actor).toBe(actor)
		expect(table.isfrozen(entry)).toBe(true)

		if entry.source == "Action" then
			expect(entry.action).toEqual({ actionId = "Match", sequenceId = 7 })
		elseif entry.source == "Tag" then
			expect(entry.tagId).toBe("Match")
		elseif entry.source == "Resource" then
			expect(entry.change.source).toBe("Commit")
			expect(entry.change.resourceId).toBe("Match")
		elseif entry.source == "Hint" then
			expect(entry.hintId).toBe("Match")
			expect(entry.payload).toBe(32)
		end
	end
end)

it("fences a retired origin before public removal and never reuses its instances on an equal id", function()
	local contexts: { Types.PresentationContext } = {}

	ready({
		{
			id = "Scoped",
			entry = { event = Events.Hint.Received, id = "Targeted" },
			create = function(context: Types.PresentationContext)
				table.insert(contexts, context)
			end,
		},
	})

	local original: ActorTypes.ActorView = installActor("SameId", {}).view
	HintState.Notify({ hintId = "Targeted", actorView = original })
	task.wait()
	expect(#contexts).toBe(1)

	for _ = 1, 2 do
		HintState.Notify({ hintId = "Targeted", actorView = original })
	end

	Actors.Invalidate(original, "ActorRemoved")
	expect(contexts[1]:IsActive()).toBe(false)
	Actors.Remove(original)
	local replacement: ActorTypes.ActorView = installActor("SameId", {}).view
	HintState.Notify({ hintId = "Targeted", actorView = original })
	HintState.Notify({ hintId = "Targeted", actorView = replacement })
	task.wait()
	expect(#contexts).toBe(2)
	expect(contexts[1].actor).toBe(original)
	expect(contexts[2].actor).toBe(replacement)
	expect(contexts[2]:IsActive()).toBe(true)
end)

it("attaches a new Actor before its public Added callback delivers a live event", function()
	local actions: ActorTypes.DomainViewOwner =
		assert(DomainView.new("KRF.Actions", {}, { "Started", "Ended", "Interrupted" }), "Expected Actions DomainView")

	local contexts: { Types.PresentationContext } = {}

	ready({
		{
			id = "Immediate",
			entry = { event = Events.Action.Started, id = "Live" },
			create = function(context: Types.PresentationContext)
				table.insert(contexts, context)
			end,
		},
	})

	-- A newer public GoodSignal listener runs ahead of any public startup listener.
	addedConnection = Registry.OnActorViewAdded:Connect(function()
		actions:FireEvent("Started", table.freeze({ actionId = "Live", sequenceId = 2 }))
	end)

	local actor: ActorTypes.ActorView = installActor("AddedDuringRuntime", { ["KRF.Actions"] = actions }).view
	Actors.Added:Fire(actor)
	task.wait()
	expect(#contexts).toBe(1)
	expect(contexts[1].actor).toBe(actor)
end)

it("keeps instances through Model loss and marks suspended construction inactive during retirement", function()
	local context: Types.PresentationContext? = nil
	local resumed: boolean = false
	local cleanupCalls: number = 0
	local owner: ActorTypes.ActorViewOwner = installActor("SuspendedActor", {})

	ready({
		{
			id = "SuspendedActor",
			entry = { event = Events.Hint.Received, id = "Targeted" },
			create = function(current: Types.PresentationContext)
				context = current
				task.wait(0.05)
				resumed = not current:IsActive()

				current:Own(function()
					cleanupCalls += 1
				end)
			end,
		},
	})

	HintState.Notify({ hintId = "Targeted", actorView = owner.view })
	task.wait()
	assert(context ~= nil, "Expected suspended Actor-scoped instance")
	local model: Model = Instance.new("Model")
	owner:InstallModel(model)
	owner:InstallModel(nil)
	model:Destroy()
	expect(context:IsActive()).toBe(true)
	Actors.Invalidate(owner.view, "ActorRemoved")
	expect(context:IsActive()).toBe(false)
	task.wait(0.1)
	expect(resumed).toBe(true)
	expect(cleanupCalls).toBe(1)
end)

it("uses late Tag and Resource domains through existing typed listeners", function()
	local owner: ActorTypes.ActorViewOwner = installActor("LateDomains", {})
	local observed: { string } = {}

	local function record(context: Types.PresentationContext): ()
		table.insert(observed, context.entry.source)
	end

	ready({
		{ id = "Status", entry = { event = Events.Tag.Added, id = "Match" }, create = record },
		{ id = "Meter", entry = { event = Events.Resource.Changed, id = "Match" }, create = record },
	})

	local tags: ActorTypes.DomainViewOwner = assert(
		DomainView.new("KRF.Tags", {}, { "Added", "Refreshed", "Removed", "Expired" }),
		"Expected Tags DomainView"
	)

	local resources: ActorTypes.DomainViewOwner =
		assert(DomainView.new("KRF.Resources", {}, {}), "Expected Resources DomainView")

	owner:InstallDomains({ ["KRF.Tags"] = tags, ["KRF.Resources"] = resources })
	task.wait()
	expect(observed).toEqual({})

	tags:FireEvent("Added", "Match")

	resources:NotifyChanged({
		previous = {},
		current = { Match = { anchorValue = 5, anchorTime = 0, min = 0, max = 10 } },
		source = "Commit",
	})

	task.wait()
	table.sort(observed)
	expect(observed).toEqual({ "Resource", "Tag" })
end)
