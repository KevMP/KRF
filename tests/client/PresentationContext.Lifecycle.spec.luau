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
local SignalTypes = require(KRF.shared.Signal.types)
local GoodSignal: any = require(KRF.shared.Signal.GoodSignal)
local Hints = require(KRF.client.Networking.utils.HintRuntimeState)

local owners: { ActorTypes.ActorViewOwner } = {}
local shutdown: (() -> ())? = nil
local fireEnvironment: any = getfenv(GoodSignal.Fire)

afterEach(function()
	setfenv(GoodSignal.Fire, fireEnvironment)

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

local function install(create: (Types.PresentationContext) -> ()): ()
	local catalog: Types.PresentationCatalog = assert(Registry.Prepare({
		{
			id = "Lifecycle",
			entry = { event = Events.Hint.Received, id = "Origin" },
			create = create,
		},
	}))

	shutdown = assert(Runtime.Install(catalog))
end

local function actor(id: string): ActorTypes.ActorViewOwner
	local owner: ActorTypes.ActorViewOwner = assert(ActorView.new(id, nil, {}))
	table.insert(owners, owner)
	assert(Actors.Install(owner.view))

	return owner
end

it("observes only future events after a yielding constructor and allows overlapping yieldable callbacks", function()
	local context: Types.PresentationContext? = nil
	local connection: SignalTypes.Connection? = nil
	local started: { number } = {}
	local continued: { boolean } = {}

	install(function(current: Types.PresentationContext)
		context = current
		task.wait(0.05)

		connection = current:On(Events.Hint.Received, "Follow", function(event: Types.HintEntryEvent)
			table.insert(started, event.payload)
			task.wait(0.05)
			table.insert(continued, current:IsActive())
		end)
	end)

	Hints.Notify({ hintId = "Origin" })
	task.wait()
	Hints.Notify({ hintId = "Follow", payload = 0 })
	task.wait(0.1)
	expect(started).toEqual({})
	Hints.Notify({ hintId = "Follow", payload = 1 })
	Hints.Notify({ hintId = "Follow", payload = 2 })
	expect(started).toEqual({})
	task.wait()
	table.sort(started)
	expect(started).toEqual({ 1, 2 })
	assert(connection ~= nil and context ~= nil, "Expected registered yielding callback")
	connection:Disconnect()
	context:Finish()
	task.wait(0.1)
	expect(continued).toEqual({ false, false })
end)

it(
	"fences queued authored work and stale GoodSignal handlers after disconnect and never replays a prior Fire",
	function()
		local context: Types.PresentationContext? = nil
		local connection: SignalTypes.Connection? = nil
		local received: number = 0

		local function record(): ()
			received += 1
		end

		install(function(current: Types.PresentationContext)
			context = current
			connection = current:On(Events.Hint.Received, "Follow", record)
		end)

		Hints.Notify({ hintId = "Origin" })
		task.wait()
		assert(connection ~= nil and context ~= nil, "Expected registered callback")
		Hints.Notify({ hintId = "Follow" })
		connection:Disconnect()
		task.wait()
		expect(received).toBe(0)
		connection = context:On(Events.Hint.Received, "Follow", record)
		local pending: { () -> () } = {}

		local taskAdapter = {
			spawn = function(_runner: thread, callback: (...any) -> (), ...: any)
				local arguments = table.pack(...)

				table.insert(pending, function(): ()
					callback(table.unpack(arguments, 1, arguments.n))
				end)
			end,
		}

		setfenv(GoodSignal.Fire, setmetatable({ task = taskAdapter }, { __index = fireEnvironment }))
		Hints.Notify({ hintId = "Follow" })
		setfenv(GoodSignal.Fire, fireEnvironment)
		connection:Disconnect()
		context:On(Events.Hint.Received, "Follow", record)

		for _, callback in pending do
			callback()
		end

		task.wait()
		expect(received).toBe(0)
		Hints.Notify({ hintId = "Follow" })
		task.wait()
		expect(received).toBe(1)
	end
)

it(
	"contains callback faults, disconnects before LIFO cleanup and permits Finish and disconnect inside callbacks",
	function()
		local contexts: { Types.PresentationContext } = {}
		local cleanup: { string } = {}
		local received: { string } = {}

		install(function(context: Types.PresentationContext)
			table.insert(contexts, context)
			local entry: Types.PresentationEntryEvent = context.entry
			assert(entry.source == "Hint", "Expected Hint origin")
			local label: string = entry.payload

			context:Own(function(): ()
				assert(not context:IsActive(), "Cleanup preceded retirement")
				table.insert(cleanup, label .. ":first")
			end)

			context:Own(function(): ()
				table.insert(cleanup, label .. ":last")
			end)

			local connection: SignalTypes.Connection

			connection = context:On(Events.Hint.Received, "Follow", function()
				table.insert(received, label)

				if label == "StringFault" then
					error("Expected callback failure")
				end

				if label == "ObjectFault" then
					error({}, 0)
				end

				connection:Disconnect()
				context:Finish()
				context:Finish()
			end)
		end)

		for _, label: string in { "StringFault", "ObjectFault", "Good" } do
			Hints.Notify({ hintId = "Origin", payload = label })
		end

		task.wait()
		Hints.Notify({ hintId = "Follow" })
		task.wait()
		task.wait()
		table.sort(received)
		expect(received).toEqual({ "Good", "ObjectFault", "StringFault" })

		for _, context in contexts do
			expect(context:IsActive()).toBe(false)
		end

		for _, label: string in received do
			local last: number = assert(table.find(cleanup, label .. ":last"))
			expect(cleanup[last + 1]).toBe(label .. ":first")
		end

		Hints.Notify({ hintId = "Follow" })
		task.wait()
		expect(#received).toBe(3)
	end
)

it("disconnects an observed retired Actor without finishing the origin and rejects equal-id replacements", function()
	local origin: ActorTypes.ActorViewOwner = actor("Origin")
	local other: ActorTypes.ActorViewOwner = actor("Other")

	local tags: ActorTypes.DomainViewOwner =
		assert(DomainView.new("KRF.Tags", {}, { "Added", "Refreshed", "Removed", "Expired" }))

	other:InstallDomains({ ["KRF.Tags"] = tags })
	local context: Types.PresentationContext? = nil
	local received: { string } = {}

	install(function(current: Types.PresentationContext)
		context = current

		current:On(Events.Tag.Added, { id = "Charging", actor = other.view }, function(event: Types.TagEntryEvent)
			table.insert(received, event.tagId)
		end)

		current:On(Events.Hint.Received, "Follow", function(event: Types.HintEntryEvent)
			expect(event.actor).toBe(origin.view)
			table.insert(received, "Hint")
		end)
	end)

	Hints.Notify({ hintId = "Origin", actorView = origin.view })
	task.wait()
	assert(context ~= nil, "Expected Actor-scoped context")
	tags:FireEvent("Added", "Charging")
	task.wait()
	expect(received).toEqual({ "Charging" })
	tags:FireEvent("Added", "Charging")
	Actors.Remove(other.view)
	expect(context:IsActive()).toBe(true)
	local replacement: ActorTypes.ActorViewOwner = actor("Other")

	local replacementTags: ActorTypes.DomainViewOwner =
		assert(DomainView.new("KRF.Tags", {}, { "Added", "Refreshed", "Removed", "Expired" }))

	replacement:InstallDomains({ ["KRF.Tags"] = replacementTags })
	tags:FireEvent("Added", "Charging")
	replacementTags:FireEvent("Added", "Charging")
	Hints.Notify({ hintId = "Follow" })
	Hints.Notify({ hintId = "Follow", actorView = replacement.view })
	Hints.Notify({ hintId = "Follow", actorView = origin.view })
	task.wait()
	expect(received).toEqual({ "Charging", "Hint" })
	local model: Model = Instance.new("Model")
	origin:InstallModel(model)
	origin:InstallModel(nil)
	model:Destroy()
	expect(context:IsActive()).toBe(true)
	Hints.Notify({ hintId = "Follow", actorView = origin.view })
	Actors.Invalidate(origin.view, "ActorRemoved")
	expect(context:IsActive()).toBe(false)
	task.wait()
	expect(received).toEqual({ "Charging", "Hint" })
end)

it("retires origin instances and observed-Actor subscriptions when the registry resets", function()
	local origin: ActorTypes.ActorViewOwner = actor("Origin")
	local other: ActorTypes.ActorViewOwner = actor("Other")

	local tags: ActorTypes.DomainViewOwner =
		assert(DomainView.new("KRF.Tags", {}, { "Added", "Refreshed", "Removed", "Expired" }))

	other:InstallDomains({ ["KRF.Tags"] = tags })
	local context: Types.PresentationContext? = nil
	local received: { string } = {}
	local cleaned: number = 0

	install(function(current: Types.PresentationContext)
		context = current

		current:Own(function()
			cleaned += 1
		end)

		current:On(Events.Tag.Added, { id = "Charging", actor = other.view }, function(event: Types.TagEntryEvent)
			table.insert(received, event.tagId)
		end)

		current:On(Events.Hint.Received, "Follow", function(_event: Types.HintEntryEvent)
			table.insert(received, "Hint")
		end)
	end)

	Hints.Notify({ hintId = "Origin", actorView = origin.view })
	task.wait()
	assert(context ~= nil, "Expected Actor-scoped context")
	tags:FireEvent("Added", "Charging")
	Hints.Notify({ hintId = "Follow", actorView = origin.view })
	Actors.Reset()
	expect(context:IsActive()).toBe(false)
	tags:FireEvent("Added", "Charging")
	Hints.Notify({ hintId = "Follow", actorView = origin.view })
	task.wait()
	expect(received).toEqual({})
	expect(cleaned).toBe(1)
end)

it("uses late Resource domains for implicit and exact ids and preserves Commit and Baseline observations", function()
	local owner: ActorTypes.ActorViewOwner = actor("Resources")
	local received: { string } = {}

	local catalog: Types.PresentationCatalog = assert(Registry.Prepare({
		{
			id = "Resource",
			entry = { event = Events.Resource.Changed, id = "Mana" },
			create = function(context: Types.PresentationContext)
				context:On(Events.Resource.Changed, function(event: Types.ResourceEntryEvent)
					expect(table.isfrozen(event)).toBe(true)
					table.insert(received, "implicit:" .. event.change.source)
				end)

				context:On(Events.Resource.Changed, "Mana", function(event: Types.ResourceEntryEvent)
					table.insert(received, "explicit:" .. event.change.source)
				end)
			end,
		},
	}))

	shutdown = assert(Runtime.Install(catalog))
	local resources: ActorTypes.DomainViewOwner = assert(DomainView.new("KRF.Resources", {}, {}))
	owner:InstallDomains({ ["KRF.Resources"] = resources })
	local anchor = table.freeze({ anchorValue = 5, anchorTime = 0, min = 0, max = 10 })
	resources:NotifyChanged({ previous = {}, current = { Mana = anchor }, source = "Commit" })
	task.wait()
	expect(received).toEqual({})
	resources:NotifyChanged({ previous = { Mana = anchor }, current = {}, source = "Baseline" })
	resources:NotifyChanged({ previous = { Mana = anchor }, current = {}, source = "Commit" })
	task.wait()
	table.sort(received)
	expect(received).toEqual({ "explicit:Baseline", "explicit:Commit", "implicit:Baseline", "implicit:Commit" })
end)

it("fences pending source and authored callbacks across shutdown and reinstallation", function()
	local contexts: { Types.PresentationContext } = {}
	local received: number = 0

	local function create(context: Types.PresentationContext): ()
		table.insert(contexts, context)

		context:On(Events.Hint.Received, "Follow", function(): ()
			received += 1
		end)
	end

	install(create)
	Hints.Notify({ hintId = "Origin" })
	task.wait()
	Hints.Notify({ hintId = "Follow" })
	assert(shutdown, "Expected installed runtime")()
	expect(contexts[1]:IsActive()).toBe(false)
	install(create)
	Hints.Notify({ hintId = "Origin" })
	task.wait()
	expect(received).toBe(0)
	Hints.Notify({ hintId = "Follow" })
	task.wait()
	expect(received).toBe(1)
	expect(contexts[2]:IsActive()).toBe(true)
end)

it("keeps automatic disposal private when authors replace their public Disconnect method", function()
	local origin: ActorTypes.ActorViewOwner = actor("Origin")
	local observed: ActorTypes.ActorViewOwner = actor("Observed")
	local contexts: { Types.PresentationContext } = {}
	local cleanups: number = 0
	local authoredDisconnects: number = 0

	install(function(context: Types.PresentationContext)
		table.insert(contexts, context)

		context:Own(function(): ()
			expect(Actors.IsInvalidationInProgress()).toBe(false)
			cleanups += 1
		end)

		local connections: { SignalTypes.Connection } = {
			context:On(Events.Hint.Received, "Follow", function(): () end),
			context:On(Events.Hint.Received, { id = "Follow", actor = observed.view }, function(): () end),
		}

		for _, connection in connections do
			connection.Disconnect = function(): ()
				authoredDisconnects += 1
				error("Automatic teardown invoked a replaced public method")
			end
		end
	end)

	Hints.Notify({ hintId = "Origin", actorView = origin.view })
	Hints.Notify({ hintId = "Origin", actorView = origin.view })
	task.wait()
	expect(#contexts).toBe(2)
	Actors.Invalidate(observed.view, "ActorRemoved")
	expect(contexts[1]:IsActive()).toBe(true)
	expect(contexts[2]:IsActive()).toBe(true)
	contexts[1]:Finish()
	Actors.Invalidate(origin.view, "ActorRemoved")
	expect(contexts[1]:IsActive()).toBe(false)
	expect(contexts[2]:IsActive()).toBe(false)
	expect(authoredDisconnects).toBe(0)
	task.wait()
	expect(cleanups).toBe(2)
end)

it("fences unavailable observed Actors before invalidation and ignores unavailable broad Hint targets", function()
	local observed: ActorTypes.ActorViewOwner = actor("Observed")
	local received: { string } = {}

	install(function(context: Types.PresentationContext)
		context:On(Events.Hint.Received, { id = "Follow", actor = observed.view }, function(): ()
			table.insert(received, "scoped")
		end)

		context:On(Events.Hint.Received, { id = "Follow", scope = "Any" }, function(): ()
			table.insert(received, "broad")
		end)
	end)

	Hints.Notify({ hintId = "Origin" })
	task.wait()
	observed:InstallUnavailable()
	Hints.Notify({ hintId = "Follow", actorView = observed.view })
	task.wait()
	expect(received).toEqual({})
	Hints.Notify({ hintId = "Follow" })
	task.wait()
	expect(received).toEqual({ "broad" })
end)
