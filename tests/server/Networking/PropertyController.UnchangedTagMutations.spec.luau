--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local ActionTypes = require(KRF.server.Action.types)
local ActorTypes = require(KRF.server.Actor.types)
local TagTypes = require(KRF.server.Tags.types)
local PropertyTypes = require(KRF.server.Property.types)
local ResourceTypes = require(KRF.server.Resource.types)
local NetworkingTypes = require(KRF.server.Networking.types)
local SignalTypes = require(KRF.shared.Signal.types)
local TagController = require(KRF.server.Tags.TagController)
local ActionUtils = require(script.Parent.Parent.Utils.Action.ActionResourceTestUtils)
local TestUtils = require(script.Parent.Parent.Utils.Networking.ActionsReplicationTestUtils)

local disconnects: { () -> () } = {}
local connections: { SignalTypes.Connection } = {}

beforeEach(function()
	ActionUtils.reset()
	disconnects = {}
	connections = {}
end)

afterEach(function()
	for _, connection: SignalTypes.Connection in connections do
		connection:Disconnect()
	end

	for _, disconnect in disconnects do
		disconnect()
	end

	ActionUtils.cleanup()
end)

local function initialize(definitions: { ActionTypes.ActionDefinition }): ()
	ActionUtils.initialize(definitions, {
		{
			id = "Mana",
			visibility = "ClientVisible",
			autoAssign = true,
			initialValue = 100,
			max = { propertyName = "MaxMana", defaultBaseValue = 100 },
		},
	}, {
		{ id = "Marker", visibility = "ClientVisible", duplicateBehavior = "Refresh" },
		{
			id = "Capacity",
			visibility = "ClientVisible",
			duplicateBehavior = "Refresh",
			properties = { MaxMana = { set = 50 } },
		},
		{
			id = "Limits",
			visibility = "ClientVisible",
			duplicateBehavior = "Ignore",
			properties = { MaxMana = { max = 100 }, WalkSpeed = { set = 16 } },
		},
		{
			id = "Masked",
			visibility = "ClientVisible",
			duplicateBehavior = "Refresh",
			properties = { MaxMana = { add = 5 }, WalkSpeed = { add = 5 } },
		},
	})
end

for _, operation: string in { "Added", "Refreshed", "Removed", "Expired" } do
	it(`skips private Property phases when standalone Tag {operation} has no modifiers or pending changes`, function()
		initialize({})

		local actor: ActorTypes.Actor, _, publicResources: ResourceTypes.ResourceController, publicProperties: PropertyTypes.PropertyController, tags: TagTypes.TagController =
			ActionUtils.registerActor()

		if operation ~= "Added" then
			expect(tags:AddTag("Marker", { duration = 1 })).toBe(true)
		end

		local properties: PropertyTypes.InternalPropertyController =
			publicProperties :: PropertyTypes.InternalPropertyController

		local resources: ResourceTypes.InternalResourceController =
			publicResources :: ResourceTypes.InternalResourceController

		local propertyCalls: number = 0
		local resourceCalls: number = 0
		local order: { string } = {}
		local commits: { NetworkingTypes.PublicationCommit } = TestUtils.observe()
		local before: NetworkingTypes.PublicationBaseline? = TestUtils.publication():CaptureBaseline(actor)
		assert(before ~= nil, "Expected admitted Actor")

		local function unexpectedPropertyDelivery(): ()
			propertyCalls += 1

			if operation == "Refreshed" or operation == "Expired" then
				coroutine.yield()
			else
				error("UnexpectedUnchangedPropertyDelivery", 0)
			end
		end

		local disconnectProperty: () -> () = properties:_observeResolvedMutations({
			Commit = unexpectedPropertyDelivery,
			Dispatch = unexpectedPropertyDelivery,
		})

		table.insert(disconnects, disconnectProperty)

		table.insert(
			disconnects,
			resources:_observeMutations({
				Commit = function(): ()
					resourceCalls += 1
				end,
				Dispatch = function(): ()
					resourceCalls += 1
				end,
			})
		)

		local event: SignalTypes.Event<ActorTypes.Actor, string> = if operation == "Added"
			then tags.OnTagAdded
			elseif operation == "Refreshed" then tags.OnTagRefreshed
			elseif operation == "Removed" then tags.OnTagRemoved
			else tags.OnTagExpired

		table.insert(
			connections,
			event:Connect(function(): ()
				table.insert(order, operation)
			end)
		)

		table.insert(
			connections,
			tags.OnTagChanged:Connect(function(): ()
				table.insert(order, "Changed")
			end)
		)

		table.insert(
			connections,
			properties.OnPropertyChanged:Connect(function(): ()
				table.insert(order, "Property")
			end)
		)

		table.insert(
			connections,
			resources.OnResourceChanged:Connect(function(): ()
				table.insert(order, "Resource")
			end)
		)

		local success: boolean, failure: any = pcall(function(): ()
			if operation == "Added" or operation == "Refreshed" then
				expect(tags:AddTag("Marker", { duration = 5 })).toBe(true)
			elseif operation == "Removed" then
				expect(tags:RemoveTag("Marker")).toBe(true)
			else
				TagController.Step(1)
			end
		end)

		expect(success).toBe(true)
		expect(failure).toBeNil()
		expect(propertyCalls).toBe(0)
		expect(resourceCalls).toBe(0)
		expect(order).toEqual({ operation, "Changed" })
		expect(tags:HasTag("Marker")).toBe(operation == "Added" or operation == "Refreshed")
		expect(properties:GetResolvedProperty("MaxMana")).toBe(100)
		expect(resources:GetMax("Mana")).toBe(100)
		expect(resources:GetCurrent("Mana")).toBe(100)
		expect(#commits).toBe(1)
		expect(commits[1].sequence).toBe(before.sequence + 1)

		expect(commits[1].events).toEqual({
			{ domainId = "KRF.Tags", eventId = operation, payload = "Marker" },
		})

		local after: NetworkingTypes.PublicationBaseline? = TestUtils.publication():CaptureBaseline(actor)
		assert(after ~= nil, "Expected retained publication")
		expect(after.domains["KRF.Resources"]).toEqual(before.domains["KRF.Resources"])
		expect(after.domains["KRF.Tags"].value.Marker ~= nil).toBe(operation == "Added" or operation == "Refreshed")
		disconnectProperty()
		expect(tags:AddTag("Capacity")).toBe(true)
		expect(resources:GetMax("Mana")).toBe(50)
		expect(properties:GetResolvedProperty("MaxMana")).toBe(50)
		expect(resourceCalls).toBe(2)
		expect(propertyCalls).toBe(0)
	end)
end

it("skips private Property delivery when clamping and overrides leave affected resolved values unchanged", function()
	initialize({})

	local actor: ActorTypes.Actor, _, publicResources: ResourceTypes.ResourceController, publicProperties: PropertyTypes.PropertyController, tags: TagTypes.TagController =
		ActionUtils.registerActor()

	expect(tags:AddTag("Limits")).toBe(true)

	local properties: PropertyTypes.InternalPropertyController =
		publicProperties :: PropertyTypes.InternalPropertyController

	local resources: ResourceTypes.InternalResourceController =
		publicResources :: ResourceTypes.InternalResourceController

	local propertyCalls: number = 0
	local resourceCalls: number = 0
	local publicChanges: number = 0
	local commits: { NetworkingTypes.PublicationCommit } = TestUtils.observe()

	local function unexpectedPropertyDelivery(): ()
		propertyCalls += 1
		error("UnexpectedMaskedPropertyDelivery", 0)
	end

	table.insert(
		disconnects,
		properties:_observeResolvedMutations({
			Commit = unexpectedPropertyDelivery,
			Dispatch = unexpectedPropertyDelivery,
		})
	)

	table.insert(
		disconnects,
		resources:_observeMutations({
			Commit = function(): ()
				resourceCalls += 1
			end,
			Dispatch = function(): ()
				resourceCalls += 1
			end,
		})
	)

	table.insert(
		connections,
		properties.OnPropertyChanged:Connect(function(): ()
			publicChanges += 1
		end)
	)

	expect(tags:AddTag("Masked")).toBe(true)
	expect(tags:RemoveTag("Masked")).toBe(true)
	expect(tags:HasTag("Limits")).toBe(true)
	expect(tags:HasTag("Masked")).toBe(false)
	expect(properties:GetResolvedProperty("MaxMana")).toBe(100)
	expect(properties:GetResolvedProperty("WalkSpeed")).toBe(16)
	expect(resources:GetMax("Mana")).toBe(100)
	expect(resources:GetCurrent("Mana")).toBe(100)
	expect(propertyCalls).toBe(0)
	expect(resourceCalls).toBe(0)
	expect(publicChanges).toBe(0)
	expect(#commits).toBe(2)
	expect(commits[1].events).toEqual({ { domainId = "KRF.Tags", eventId = "Added", payload = "Masked" } })
	expect(commits[2].events).toEqual({ { domainId = "KRF.Tags", eventId = "Removed", payload = "Masked" } })
	local current: NetworkingTypes.PublicationBaseline? = TestUtils.publication():CaptureBaseline(actor)
	assert(current ~= nil, "Expected unchanged Resource publication")
	expect(current.domains["KRF.Resources"].value.Mana.max).toBe(100)
end)

it("finishes late Resource delivery after reentry drained the Property journal before its Commit failed", function()
	initialize({})

	local actor: ActorTypes.Actor, _, publicResources: ResourceTypes.ResourceController, publicProperties: PropertyTypes.PropertyController, tags: TagTypes.TagController =
		ActionUtils.registerActor()

	local resources: ResourceTypes.InternalResourceController =
		publicResources :: ResourceTypes.InternalResourceController

	local properties: PropertyTypes.InternalPropertyController =
		publicProperties :: PropertyTypes.InternalPropertyController

	local order: { string } = {}
	local nestedResult: boolean? = nil
	local insideCommit: { string } = {}
	local changes: { ResourceTypes.ResourceChange } = {}
	local original = { reason = "LateResourceCommitFailure" }
	local resourceDispatches: number = 0
	local propertyCommits: { { string } } = {}
	local commits: { NetworkingTypes.PublicationCommit } = TestUtils.observe()

	table.insert(
		connections,
		tags.OnTagAdded:Connect(function(_actor: ActorTypes.Actor, tagId: string): ()
			table.insert(order, "Added " .. tagId)
		end)
	)

	table.insert(
		connections,
		tags.OnTagChanged:Connect(function(_actor: ActorTypes.Actor, tagId: string): ()
			table.insert(order, "Changed " .. tagId)
		end)
	)

	table.insert(
		connections,
		properties.OnResolvedPropertyChanged:Connect(function(): ()
			table.insert(order, "Resolved")
		end)
	)

	table.insert(
		connections,
		properties.OnPropertyChanged:Connect(function(): ()
			table.insert(order, "Property")
		end)
	)

	table.insert(
		connections,
		resources.OnResourceChanged:Connect(function(change: ResourceTypes.ResourceChange): ()
			table.insert(changes, change)
			table.insert(order, "Resource")
		end)
	)

	table.insert(
		disconnects,
		properties:_observeResolvedMutations({
			Commit = function(names: { string }): ()
				table.insert(propertyCommits, table.clone(names))
			end,
			Dispatch = function(): () end,
		})
	)

	local disconnectFailure: () -> () = resources:_observeMutations({
		Commit = function(): ()
			nestedResult = tags:AddTag("Marker")
			insideCommit = table.clone(order)
			error(original, 0)
		end,
		Dispatch = function(): ()
			resourceDispatches += 1
		end,
	})

	table.insert(disconnects, disconnectFailure)

	local success: boolean, failure: any = pcall(function(): ()
		tags:AddTag("Capacity")
	end)

	expect(success).toBe(false)
	expect(failure).toBe(original)
	expect(nestedResult).toBe(true)
	expect(insideCommit).toEqual({ "Added Marker", "Changed Marker", "Resolved", "Property" })

	expect(order).toEqual({
		"Added Marker",
		"Changed Marker",
		"Resolved",
		"Property",
		"Added Capacity",
		"Changed Capacity",
		"Resource",
	})

	expect(propertyCommits).toEqual({ { "MaxMana" } })
	expect(resourceDispatches).toBe(1)
	expect(#changes).toBe(1)
	expect(changes[1].maxOldValue).toBe(100)
	expect(changes[1].maxNewValue).toBe(50)
	expect(resources:GetCurrent("Mana")).toBe(50)
	expect(properties:GetResolvedProperty("MaxMana")).toBe(50)
	expect(tags:HasTag("Marker")).toBe(true)
	expect(tags:HasTag("Capacity")).toBe(true)
	expect(#commits).toBe(3)
	local admitted: NetworkingTypes.PublicationBaseline? = TestUtils.publication():CaptureBaseline(actor)
	assert(admitted ~= nil, "Expected coherent current publication")
	expect(admitted.domains["KRF.Resources"].value.Mana.max).toBe(50)
	expect(admitted.domains["KRF.Tags"].value.Marker).never.toBeNil()
	expect(admitted.domains["KRF.Tags"].value.Capacity).never.toBeNil()
	disconnectFailure()
	expect(tags:RemoveTag("Capacity")).toBe(true)
	expect(resources:GetMax("Mana")).toBe(100)
	expect(resources:GetCurrent("Mana")).toBe(50)
	expect(#changes).toBe(2)
end)

it("drains a pending real Property batch through an unchanged Tag once and preserves its Dispatch error", function()
	initialize({})

	local actor: ActorTypes.Actor, _, resources: ResourceTypes.ResourceController, publicProperties: PropertyTypes.PropertyController, publicTags: TagTypes.TagController =
		ActionUtils.registerActor()

	local tags: TagTypes.InternalTagController = publicTags :: TagTypes.InternalTagController

	local properties: PropertyTypes.InternalPropertyController =
		publicProperties :: PropertyTypes.InternalPropertyController

	local original = { reason = "PendingPropertyDispatchFailure" }
	local propertyCommits: { { string } } = {}
	local dispatches: number = 0
	local order: { string } = {}
	local commits: { NetworkingTypes.PublicationCommit } = TestUtils.observe()

	local disconnectFailure: () -> () = properties:_observeResolvedMutations({
		Commit = function(names: { string }): ()
			table.insert(propertyCommits, table.clone(names))
		end,
		Dispatch = function(): ()
			dispatches += 1
			error(original, 0)
		end,
	})

	table.insert(disconnects, disconnectFailure)

	table.insert(
		connections,
		tags.OnTagAdded:Connect(function(_actor: ActorTypes.Actor, tagId: string): ()
			table.insert(order, "Added " .. tagId)
		end)
	)

	table.insert(
		connections,
		tags.OnTagChanged:Connect(function(_actor: ActorTypes.Actor, tagId: string): ()
			table.insert(order, "Changed " .. tagId)
		end)
	)

	table.insert(
		connections,
		properties.OnPropertyChanged:Connect(function(): ()
			table.insert(order, "Property")
		end)
	)

	table.insert(
		connections,
		resources.OnResourceChanged:Connect(function(): ()
			table.insert(order, "Resource")
		end)
	)

	tags:_beginMutationBatch()
	expect(tags:AddTag("Capacity")).toBe(true)
	local pending: { TagTypes.TagMutationEvent } = tags:_finishMutationBatch()
	expect(order).toEqual({})
	expect(propertyCommits).toEqual({ { "MaxMana" } })
	expect(dispatches).toBe(0)

	local success: boolean, failure: any = pcall(function(): ()
		tags:AddTag("Marker")
	end)

	expect(success).toBe(false)
	expect(failure).toBe(original)
	expect(dispatches).toBe(1)
	expect(propertyCommits).toEqual({ { "MaxMana" } })
	expect(order).toEqual({ "Added Marker", "Changed Marker", "Property", "Resource" })
	expect(resources:GetCurrent("Mana")).toBe(50)
	expect(resources:GetMax("Mana")).toBe(50)
	tags:_dispatchMutationEvents(pending)
	expect(dispatches).toBe(1)

	expect(order).toEqual({
		"Added Marker",
		"Changed Marker",
		"Property",
		"Resource",
		"Added Capacity",
		"Changed Capacity",
	})

	expect(#commits).toBe(3)
	local current: NetworkingTypes.PublicationBaseline? = TestUtils.publication():CaptureBaseline(actor)
	assert(current ~= nil, "Expected current truth after one pending drain")
	expect(current.domains["KRF.Resources"].value.Mana.max).toBe(50)
	disconnectFailure()
	expect(tags:RemoveTag("Capacity")).toBe(true)
	expect(resources:GetMax("Mana")).toBe(100)
	expect(dispatches).toBe(1)
end)

it(
	"preserves paid Action publication and lifecycle recovery after a Resource observer yields with marker Tags",
	function()
		local order: { string } = {}

		initialize({
			{
				id = "Worker",
				visibility = "ClientVisible",
				autoGrant = true,
				costs = { Mana = 10 },
				activeTags = { "Marker" },
				onStart = function(): ()
					table.insert(order, "start")
				end,
				onEnd = function(): ()
					table.insert(order, "end")
				end,
			},
		})

		local actor: ActorTypes.Actor, actions: ActionTypes.ActionController, publicResources: ResourceTypes.ResourceController, publicProperties: PropertyTypes.PropertyController, tags: TagTypes.TagController =
			ActionUtils.registerActor()

		local properties: PropertyTypes.InternalPropertyController =
			publicProperties :: PropertyTypes.InternalPropertyController

		local resources: ResourceTypes.InternalResourceController =
			publicResources :: ResourceTypes.InternalResourceController

		local propertyCalls: number = 0
		local dispatches: number = 0
		local observerThread: thread? = nil
		local resumed: boolean = false
		local publication: NetworkingTypes.PublicationRuntime = TestUtils.publication()
		local before: number = publication:GetActorSequence(actor)
		local commits: { NetworkingTypes.PublicationCommit } = {}

		local function unexpectedPropertyDelivery(): ()
			propertyCalls += 1
			error("UnexpectedMarkerPropertyDelivery", 0)
		end

		table.insert(
			disconnects,
			properties:_observeResolvedMutations({
				Commit = unexpectedPropertyDelivery,
				Dispatch = unexpectedPropertyDelivery,
			})
		)

		local disconnectFailure: () -> () = resources:_observeMutations({
			Commit = function(): ()
				observerThread = coroutine.running()
				coroutine.yield()
				resumed = true
			end,
			Dispatch = function(): ()
				dispatches += 1
			end,
		})

		table.insert(disconnects, disconnectFailure)

		table.insert(
			disconnects,
			publication:ObserveCommits(function(commit: NetworkingTypes.PublicationCommit): ()
				table.insert(commits, commit)
				table.insert(order, "Publication")
			end)
		)

		table.insert(
			connections,
			actions.OnActionStarted:Connect(function(): ()
				table.insert(order, "Started")
			end)
		)

		table.insert(
			connections,
			actions.OnActionEnded:Connect(function(): ()
				table.insert(order, "Ended")
			end)
		)

		table.insert(
			connections,
			tags.OnTagAdded:Connect(function(): ()
				table.insert(order, "Added")
			end)
		)

		table.insert(
			connections,
			tags.OnTagRemoved:Connect(function(): ()
				table.insert(order, "Removed")
			end)
		)

		table.insert(
			connections,
			tags.OnTagChanged:Connect(function(): ()
				table.insert(order, "Changed")
			end)
		)

		table.insert(
			connections,
			resources.OnResourceChanged:Connect(function(): ()
				table.insert(order, "Resource")
			end)
		)

		local success: boolean, failure: any = pcall(function(): ()
			actions:RequestAction("Worker")
		end)

		expect(success).toBe(false)
		expect(failure).toBe("ResourceMutationObserverYielded")
		expect(observerThread).never.toBeNil()
		assert(observerThread ~= nil, "Expected actual Resource observer yield")
		expect(coroutine.status(observerThread)).toBe("dead")
		expect(resumed).toBe(false)
		expect(propertyCalls).toBe(0)
		expect(dispatches).toBe(1)
		expect(order).toEqual({ "Publication", "Started", "Added", "Changed", "Resource", "start" })
		expect(resources:GetCurrent("Mana")).toBe(90)
		expect(tags:HasTag("Marker")).toBe(true)
		expect(TestUtils.state(actor)).toEqual({ [1] = "Worker" })
		local admitted: NetworkingTypes.PublicationBaseline? = publication:CaptureBaseline(actor)
		assert(admitted ~= nil, "Expected coherent paid Action publication after cancellation")
		expect(admitted.domains["KRF.Resources"].value.Mana.anchorValue).toBe(90)
		expect(admitted.domains["KRF.Tags"].value.Marker).never.toBeNil()
		expect(#commits).toBe(1)
		expect(admitted.sequence).toBe(before + 1)
		disconnectFailure()
		expect(actions:EndAction(1)).toBe(true)
		expect(actions:RequestAction("Worker")).toEqual({ accepted = true, sequenceId = 2 })
		expect(propertyCalls).toBe(0)
		expect(dispatches).toBe(1)
		expect(resources:GetCurrent("Mana")).toBe(80)
		expect(TestUtils.state(actor)).toEqual({ [2] = "Worker" })
		expect(tags:HasTag("Marker")).toBe(true)
		expect(publication:GetActorSequence(actor)).toBe(before + 3)
		expect(#commits).toBe(3)
		local history: { string } = {}

		for _, commit: NetworkingTypes.PublicationCommit in commits do
			for _, event: NetworkingTypes.PublicationEvent in TestUtils.events(commit) do
				table.insert(history, event.eventId .. ":" .. event.payload.sequenceId)
			end
		end

		expect(history).toEqual({ "Started:1", "Ended:1", "Started:2" })
	end
)
